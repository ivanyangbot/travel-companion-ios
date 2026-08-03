"""Server-side Apple Maps POI verification for AI itinerary suggestions."""

from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass
from math import asin, cos, radians, sin, sqrt
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener


class AppleMapsUnconfigured(RuntimeError):
    pass


class AppleMapsProviderError(RuntimeError):
    pass


class _NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, _request, _fp, _code, _msg, _headers, _new_url):
        return None


@dataclass(frozen=True)
class VerifiedPlace:
    name: str
    address: str | None
    latitude: float
    longitude: float
    place_id: str | None
    region: str


class AppleMapsClient:
    """Small client for Apple Maps Server API Search.

    Apple Developer issues a long-lived Maps auth token (Maps > Tokens, Token
    Type = Server API). Business endpoints such as ``/v1/search`` require the
    short-lived access token exchanged at ``GET /v1/token`` (30 minutes), so
    the client caches it and refreshes slightly before expiry.
    """

    def __init__(self, *, token: str, timeout_seconds: float = 8.0):
        self._token = token
        self._timeout_seconds = timeout_seconds
        self._access_token: str | None = None
        self._access_token_expires_at = 0.0
        self._token_lock = threading.Lock()

    def search_places(self, *, query: str, destination: str | None, limit: int = 5) -> list[dict]:
        """Return named, destination-fenced Apple POIs for an AI tool call."""
        return self._search_destination_terms((query,), destination=destination, limit=limit)

    def _search_destination_terms(self, terms: tuple[str, ...], *, destination: str | None, limit: int) -> list[dict]:
        if not destination:
            return []
        self._ensure_configured()
        center = self._geocode_destination(destination)
        if center is None:
            return []
        radius = _fence_radius_meters(destination)
        region = _search_region(center, radius)
        candidates: list[dict] = []
        for term in terms:
            candidates += self._search(term, None, limit=limit, region=region)
            candidates += self._search(term, center, limit=limit, lang="en-US")
        results: list[dict] = []
        seen: set[str] = set()
        for candidate in candidates:
            coordinate = _coordinate(candidate)
            name = _text(candidate, "name", "displayName", "title")
            marker = _text(candidate, "id", "placeId") or str(coordinate)
            if not coordinate or not name or marker in seen or _distance_meters(center, coordinate) > radius:
                continue
            seen.add(marker)
            results.append({
                "name": name,
                "address": _address(candidate),
                "latitude": coordinate[0],
                "longitude": coordinate[1],
                "placeId": _text(candidate, "id", "placeId"),
            })
            if len(results) >= limit:
                break
        return results

    def verify_place(self, *, query: str, region_hint: str | None, destination: str | None, search_query: str | None = None) -> VerifiedPlace | None:
        """Verify an AI place hint against Apple Maps inside a destination fence.

        ``query`` is the user-facing (usually Chinese) name; ``search_query`` is
        the local-language/English name the model provides for map retrieval.
        Foreign destinations rarely resolve Chinese POI names, so the local
        name is tried first.
        """
        if not destination:
            return None
        self._ensure_configured()
        destination_coordinate = self._geocode_destination(destination)
        if destination_coordinate is None:
            return None

        # Apple Search scopes ranking around searchLocation. The subsequent
        # distance check is the non-negotiable fence, independent of ranking.
        terms = list(dict.fromkeys(term for term in (search_query, query) if term))
        max_distance_meters = _fence_radius_meters(destination)
        # searchRegion + required is Apple's hard geographic constraint;
        # searchLocation alone is only a ranking hint and can return places
        # on the other side of the world for ambiguous queries.
        fence_region = _search_region(destination_coordinate, max_distance_meters)
        match_names = [name for name in (search_query, query) if name]
        for term in terms:
            for search_term in (f"{term} {region_hint}".strip() if region_hint else term, term):
                # Required-region search is the hard geographic constraint but
                # ranks local-language names best; the searchLocation-hint
                # search ranks English names better. Merge both — every
                # candidate still has to pass the distance fence below.
                candidates = self._search(search_term, None, limit=10, region=fence_region)
                candidates += self._search(search_term, destination_coordinate, limit=10)
                # English index often names foreign POIs differently than the
                # localized index (e.g. "Baluran National Park" vs "Taman
                # Nasional Baluran"); merge both name spaces.
                candidates += self._search(search_term, destination_coordinate, limit=10, lang="en-US")
                seen: set = set()
                for candidate in candidates:
                    marker = _text(candidate, "id", "placeId") or str(_coordinate(candidate))
                    if marker in seen:
                        continue
                    seen.add(marker)
                    coordinate = _coordinate(candidate)
                    name = _text(candidate, "name", "displayName", "title")
                    if coordinate is None or not name:
                        continue
                    if not any(_names_match(match, name) for match in match_names):
                        continue
                    if _distance_meters(destination_coordinate, coordinate) > max_distance_meters:
                        continue
                    return VerifiedPlace(
                        name=name,
                        address=_address(candidate),
                        latitude=coordinate[0],
                        longitude=coordinate[1],
                        place_id=_text(candidate, "id", "placeId"),
                        region=region_hint or destination,
                    )
        return None

    def _geocode_destination(self, destination: str) -> tuple[float, float] | None:
        """Resolve the trip destination to a coordinate.

        Apple's zh-CN index confidently resolves obscure foreign Chinese names
        to unrelated Chinese places (e.g. 外南梦 -> a Zhejiang reef), while the
        en-US index understands them (外南梦 -> Banyuwangi, ID). Try en-US
        first, then zh-CN, then the dedicated geocoder.
        """
        for lang in ("en-US", "zh-CN"):
            results = self._search(destination, None, limit=1, lang=lang)
            coordinate = _coordinate(results[0]) if results else None
            if coordinate is not None:
                return coordinate
        return None

    def _ensure_configured(self) -> None:
        if not self._token:
            raise AppleMapsUnconfigured

    def _authorization(self) -> str:
        """Return a valid short-lived access token, refreshing it when stale."""
        with self._token_lock:
            if self._access_token and time.time() < self._access_token_expires_at - 60:
                return self._access_token
            request = Request(
                "https://maps-api.apple.com/v1/token",
                headers={"Authorization": f"Bearer {self._token}", "Accept": "application/json"},
                method="GET",
            )
            try:
                with build_opener(_NoRedirectHandler()).open(request, timeout=self._timeout_seconds) as response:
                    payload = json.loads(response.read(64 * 1024))
                access_token = payload["accessToken"]
                expires_in = int(payload["expiresInSeconds"])
            except (HTTPError, URLError, TimeoutError, OSError, KeyError, TypeError, ValueError, UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise AppleMapsProviderError from exc
            self._access_token = access_token
            self._access_token_expires_at = time.time() + expires_in
            return access_token

    def _search(self, query: str, coordinate: tuple[float, float] | None, *, limit: int, lang: str = "zh-CN", region: str | None = None, _retried: bool = False) -> list[dict]:
        parameters: dict[str, str | int] = {"q": query, "lang": lang, "limit": limit}
        if region:
            # Apple rejects combining searchRegion with searchLocation; the
            # required region is the stronger constraint and wins.
            parameters["searchRegion"] = region
            parameters["searchRegionPriority"] = "required"
        elif coordinate:
            parameters["searchLocation"] = f"{coordinate[0]:.6f},{coordinate[1]:.6f}"
        request = Request(
            f"https://maps-api.apple.com/v1/search?{urlencode(parameters)}",
            headers={"Authorization": f"Bearer {self._authorization()}", "Accept": "application/json"},
            method="GET",
        )
        try:
            with build_opener(_NoRedirectHandler()).open(request, timeout=self._timeout_seconds) as response:
                payload = json.loads(response.read(512 * 1024))
        except HTTPError as exc:
            # A cached access token can expire mid-flight; refresh once and
            # retry before surfacing a provider failure.
            if exc.code == 401 and not _retried:
                with self._token_lock:
                    self._access_token = None
                return self._search(query, coordinate, limit=limit, lang=lang, region=region, _retried=True)
            raise AppleMapsProviderError from exc
        except (URLError, TimeoutError, OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise AppleMapsProviderError from exc
        # Apple Search returns result objects; accepting these documented/common
        # envelopes also keeps the parser robust across API response versions.
        for key in ("results", "places", "data"):
            value = payload.get(key) if isinstance(payload, dict) else None
            if isinstance(value, list):
                return [item for item in value if isinstance(item, dict)]
        return []


def _address(value: dict) -> str | None:
    """Apple Maps Server API returns address lines, not a single string."""
    lines = value.get("formattedAddressLines")
    if isinstance(lines, list):
        parts = [line.strip() for line in lines if isinstance(line, str) and line.strip()]
        if parts:
            return "".join(parts)
    structured = value.get("structuredAddress")
    if isinstance(structured, dict):
        parts = [
            structured.get(key).strip()
            for key in ("locality", "subLocality", "fullThoroughfare")
            if isinstance(structured.get(key), str) and structured.get(key).strip()
        ]
        if parts:
            return "".join(parts)
    return _text(value, "formattedAddress", "address", "fullAddress")


def _text(value: dict, *keys: str) -> str | None:
    for key in keys:
        candidate = value.get(key)
        if isinstance(candidate, str) and candidate.strip():
            return candidate.strip()
    return None


def _coordinate(value: dict) -> tuple[float, float] | None:
    source = value.get("coordinate") if isinstance(value.get("coordinate"), dict) else value
    latitude = source.get("latitude", source.get("lat"))
    longitude = source.get("longitude", source.get("lng", source.get("lon")))
    if not isinstance(latitude, (int, float)) or not isinstance(longitude, (int, float)):
        return None
    if not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
        return None
    return float(latitude), float(longitude)


def _names_match(query: str, candidate: str) -> bool:
    normalized_query = "".join(char for char in query.casefold() if char.isalnum())
    normalized_candidate = "".join(char for char in candidate.casefold() if char.isalnum())
    if len(normalized_query) >= 2 and (normalized_query in normalized_candidate or normalized_candidate in normalized_query):
        return True
    # Substring matching fails when the provider inserts extra words
    # ("Banyuwangi Train Station" vs "Banyuwangi Lama Train Station"). Accept
    # full token containment for space-separated (non-CJK) names instead.
    query_tokens = [token for token in ("".join(char if char.isalnum() else " " for char in query.casefold())).split() if len(token) >= 2]
    candidate_tokens = set(("".join(char if char.isalnum() else " " for char in candidate.casefold())).split())
    if len(query_tokens) >= 2 and all(token in candidate_tokens for token in query_tokens):
        return True
    # The localized index may answer in a different language entirely
    # ("Baluran National Park" vs "Taman Nasional Baluran"). Accept when a
    # distinctive (non-generic) query token appears in the candidate name.
    distinctive = [token for token in query_tokens if len(token) >= 4 and token not in _GENERIC_NAME_TOKENS]
    return bool(distinctive) and any(token in normalized_candidate for token in distinctive)


_GENERIC_NAME_TOKENS = {
    "park", "national", "hotel", "station", "resort", "beach", "temple",
    "museum", "restaurant", "city", "center", "centre", "airport", "train",
    "island", "lake", "mount", "mountain", "grand", "international",
}


def _search_region(center: tuple[float, float], radius_meters: float) -> str:
    """Build Apple's ``searchRegion`` bounding box: north,east,south,west."""
    latitude, longitude = center
    lat_delta = radius_meters / 111_320
    lon_delta = radius_meters / (111_320 * max(0.01, abs(cos(radians(latitude)))))
    north = min(90.0, latitude + lat_delta)
    south = max(-90.0, latitude - lat_delta)
    east = min(180.0, longitude + lon_delta)
    west = max(-180.0, longitude - lon_delta)
    return f"{north:.6f},{east:.6f},{south:.6f},{west:.6f}"


def _distance_meters(left: tuple[float, float], right: tuple[float, float]) -> float:
    lat1, lon1, lat2, lon2 = map(radians, (*left, *right))
    a = sin((lat2 - lat1) / 2) ** 2 + cos(lat1) * cos(lat2) * sin((lon2 - lon1) / 2) ** 2
    return 6_371_000 * 2 * asin(sqrt(a))


def _fence_radius_meters(destination: str) -> float:
    # District/street-level destinations get a tight fence; city-level and
    # above allow legitimate day trips (national parks, volcano trailheads,
    # outlying beaches) while still excluding cross-city false positives.
    return 35_000 if any(part in destination for part in ("区", "镇", "街道")) else 80_000
