"""Minimal OpenAI-compatible AI proxy for temporary itinerary drafts.

The service never logs or persists user source text, provider payloads, prompts,
or secrets. Callers receive only normalized drafts or stable public errors.
"""

from __future__ import annotations

import json
import logging
import re
from datetime import date
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener

from ..config import ai_base_url_is_allowed


_logger = logging.getLogger(__name__)


class AIIntegrationUnconfigured(RuntimeError):
    pass


class AIProviderError(RuntimeError):
    pass


class AIInvalidOutputError(RuntimeError):
    pass


class _NoRedirectHandler(HTTPRedirectHandler):
    """Never forward an Authorization header to a redirect target."""

    def redirect_request(self, _request, _fp, _code, _msg, _headers, _new_url):
        return None


class AIItineraryClient:
    def __init__(self, *, base_url: str, api_key: str, model: str, timeout_seconds: float, max_output_tokens: int, allow_local_http: bool = False, vision_model: str = "", vision_max_output_tokens: int = 0):
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._model = model
        self._vision_model = vision_model
        self._timeout_seconds = timeout_seconds
        self._max_output_tokens = max_output_tokens
        self._vision_max_output_tokens = vision_max_output_tokens or min(max_output_tokens, 4_096)
        self._allow_local_http = allow_local_http

    def generate(self, *, source_text: str, start_date: date, days: int, preferences: str | None, images: list[str] | None = None, existing_itinerary: list[dict] | None = None) -> object:
        has_images = bool(images)
        chosen_model = (self._vision_model or self._model) if has_images else self._model
        if (
            not self._base_url
            or not self._api_key
            or not chosen_model
            or not ai_base_url_is_allowed(self._base_url, allow_local_http=self._allow_local_http)
        ):
            raise AIIntegrationUnconfigured
        endpoint = self._base_url if self._base_url.endswith("/chat/completions") else f"{self._base_url}/chat/completions"
        system_prompt = (
            "Return JSON only, with exactly {days:[{date,cards}]}. Each card must have "
            "kind (flight|hotel|activity), title, date (YYYY-MM-DD), time (HH:MM or null), "
            "place (string or null), notes (string or null). Do not invent booking details. "
            "If the user prompt includes existingItinerary, those cards are already on the trip: "
            "suggest only NEW cards that complement them, do not duplicate what is already there, "
            "and return only the days you are adding cards to (each date within the trip range)."
        )
        user_payload: dict = {
            "sourceText": source_text,
            "startDate": start_date.isoformat(),
            "days": days,
            "preferences": preferences,
        }
        if existing_itinerary:
            user_payload["existingItinerary"] = existing_itinerary
        user_text = json.dumps(user_payload, ensure_ascii=False)
        if has_images:
            user_content: list = [{"type": "text", "text": user_text}]
            for image_data_uri in images:
                user_content.append({"type": "image_url", "image_url": {"url": image_data_uri}})
            messages = [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content},
            ]
        else:
            messages = [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_text},
            ]
        return self._post_chat(
            endpoint,
            messages,
            model=chosen_model,
            max_tokens=self._vision_max_output_tokens if has_images else self._max_output_tokens,
        )

    def generate_itinerary_chat(self, *, messages: list[dict], start_date: date, days: int, preferences: str | None, destination: str | None = None, images: list[str] | None = None, existing_itinerary: list[dict] | None = None, poi_search=None) -> object:
        """Run a stateless multi-turn itinerary chat.

        The caller replays the full message history each turn; the server keeps
        none of it. The model returns ``{"reply": str, "cards": [...]}`` where
        ``cards`` is the latest batch of proposed itinerary cards (possibly
        empty while only discussing). The trip's existing cards are surfaced as
        read-only context so the model enriches rather than duplicates.
        """
        endpoint, chat_messages, chosen_model, max_tokens = self._itinerary_chat_messages(
            messages=messages,
            start_date=start_date,
            days=days,
            destination=destination,
            preferences=preferences,
            images=images,
            existing_itinerary=existing_itinerary,
        )
        if poi_search is not None:
            return self._post_itinerary_chat_with_poi_tool(
                endpoint, chat_messages, model=chosen_model, max_tokens=max_tokens, poi_search=poi_search,
            )
        content = self._post_chat_text(endpoint, chat_messages, model=chosen_model, max_tokens=max_tokens)
        try:
            return chat_output_from_text(content)
        except AIInvalidOutputError:
            # Tolerate models that ignore the NDJSON contract and return the
            # legacy single JSON object instead.
            return _extract_json(content)

    def generate_itinerary_chat_stream(self, *, messages: list[dict], start_date: date, days: int, preferences: str | None, destination: str | None = None, images: list[str] | None = None, existing_itinerary: list[dict] | None = None, poi_search=None):
        """Streaming variant of ``generate_itinerary_chat``.

        The model emits NDJSON lines; each completed line becomes an event:
        ``thinking``/``reply`` deltas, ``card`` (core fields), ``cardx``
        (extended fields for the previous card), then a final ``output`` event
        with the assembled ``{"reply", "cards"}`` payload for validation.
        """
        endpoint, chat_messages, chosen_model, max_tokens = self._itinerary_chat_messages(
            messages=messages,
            start_date=start_date,
            days=days,
            destination=destination,
            preferences=preferences,
            images=images,
            existing_itinerary=existing_itinerary,
        )
        if poi_search is None:
            yield from self._post_chat_stream(endpoint, chat_messages, model=chosen_model, max_tokens=max_tokens)
            return
        # A place card is not allowed until the model has queried this server-side
        # tool. Apple credentials stay on the server; the model sees only fenced
        # real POI candidates and must choose one of them before responding.
        output = self._post_itinerary_chat_with_poi_tool(
            endpoint, chat_messages, model=chosen_model, max_tokens=max_tokens, poi_search=poi_search,
        )
        reply = output.get("reply") if isinstance(output, dict) else None
        cards = output.get("cards") if isinstance(output, dict) else None
        if not isinstance(reply, str) or not isinstance(cards, list):
            raise AIInvalidOutputError("tool output")
        if reply:
            yield {"type": "reply", "text": reply}
        for card in cards:
            if isinstance(card, dict):
                yield {"type": "card", "value": card}
        yield {"type": "output", "value": output}

    def _itinerary_chat_messages(self, *, messages: list[dict], start_date: date, days: int, preferences: str | None, destination: str | None = None, images: list[str] | None = None, existing_itinerary: list[dict] | None = None) -> tuple[str, list, str, int]:
        """Build the OpenAI-compatible chat payload shared by both call styles."""
        has_images = bool(images)
        chosen_model = (self._vision_model or self._model) if has_images else self._model
        if (
            not self._base_url
            or not self._api_key
            or not chosen_model
            or not ai_base_url_is_allowed(self._base_url, allow_local_http=self._allow_local_http)
        ):
            raise AIIntegrationUnconfigured
        endpoint = self._base_url if self._base_url.endswith("/chat/completions") else f"{self._base_url}/chat/completions"
        context: dict = {"startDate": start_date.isoformat(), "days": days, "destination": destination, "preferences": preferences}
        if existing_itinerary:
            context["existingItinerary"] = existing_itinerary
        system_prompt = (
            "你是一位旅行行程助手，通过对话帮用户规划或补充行程，用简体中文回复。"
            "严格按 NDJSON 输出：每行一个独立 JSON 对象，不要输出任何其他文字或代码围栏。按以下顺序逐行输出："
            "1) 1-3 行 {\"t\":\"think\",\"d\":\"...\"}：你的简短思考过程（中文，分析用户需求、目的地与日期约束）；"
            "2) 若干行 {\"t\":\"reply\",\"d\":\"...\"}：给用户的简短中文回复，可拆成 2-4 行依次输出；"
            "3) 每张提议卡片两行：先 {\"t\":\"card\",\"kind\":...,\"title\":...,\"date\":...,\"time\":...,\"place\":...,\"placeSearch\":...,\"region\":...}，"
            "紧接一行 {\"t\":\"cardx\",\"description\":...,\"url\":...,\"priceMinor\":...,\"notes\":...,\"bookingCode\":...,\"fromAirport\":...,\"toAirport\":...}。"
            "仅讨论不提议卡片时不输出 card/cardx 行。"
            "card 行字段：kind (flight|hotel|activity)、title（简短活动名，如「故宫游览」，不要写地点）、"
            "date (YYYY-MM-DD，需在旅行范围内)、time (HH:MM 或 null)、"
            "place（展示给用户的中文地点名，如「故宫博物院」「外南梦火车站」）、"
            "placeSearch（供 Apple 地图检索的官方全名，优先当地语言如印尼语「Stasiun Banyuwangi Kota」、日语「浅草寺」，其次英文；境外目的地必填，国内可与 place 相同）、"
            "region（行政区/商圈/岛屿名，不能是经纬度）。"
            "【地点职责】先用你自己的旅行知识为用户提名热门景点、酒店和当地名称；Apple Maps 工具只负责把你提名的名称解析成真实 POI、坐标和目的地围栏校验。"
            "生成每张 hotel/activity 卡片前，必须用 search_destination_pois 查询你提出的具体名称（可依次尝试英文、当地语言、常见别名）。"
            "一次查询无候选只代表该名称/拼写未命中，不代表目的地没有景点；换用你的知识中的别名、当地语言或另一处热门地点继续查询。"
            "只有某次查询返回候选后才可生成卡片：place 可为中文展示名，placeSearch 必须逐字采用该候选的 name；服务端将以候选坐标和地址为准。"
            "place 与 placeSearch 必须是同一个具体实体的名称；不能使用区域、类别、行程意图或泛称代替地点。"
            "严禁输出「市区酒店」「市中心酒店」「附近住宿」「当地夜市」「夜市美食探索」「海边散步」「城区游览」「自由活动」及任何同类模糊表述。"
            "在尝试名称、别名或当地语言后仍未命中具体 POI，或只能想到泛化活动时：只用 reply 提出建议或询问用户偏好，绝不输出 card/cardx；绝不能声称目的地没有 Apple Maps POI。"
            "cardx 行字段尽量填全：description（2-3 句中文简介，亮点/历史/适合人群）、"
            "notes（中文实用贴士：预约、交通、穿着、排队等）、url（公开 https 介绍页，不确定则 null）、"
            "priceMinor（预估参考价，整数最小货币单位，如 6000 表示 60.00；不确定则 null）、"
            "bookingCode/fromAirport/toAirport（仅 flight，航班号与起降机场）。"
            "若行程上下文提供 destination，place、placeSearch 和 region 必须位于该目的地或其紧邻交通枢纽；"
            "地点不确定、无法确认属于目的地、无法确认是唯一具体 POI 时，不要生成该卡片。"
            "activity 和 hotel 卡片必须填写具体 place 与具体 placeSearch；只有 flight 卡片可为 null。"
            "若上下文含 existingItinerary，这些卡片已在行程中：只提议互补的新卡片，不要重复已有内容。"
            "每轮可提议多张卡片。不要编造订单号、联系方式或精确票价；priceMinor 只是预估参考。"
            f"\n\n行程上下文: {json.dumps(context, ensure_ascii=False)}"
        )
        chat_messages: list = [{"role": "system", "content": system_prompt}]
        for message in messages:
            chat_messages.append({"role": message["role"], "content": message["content"]})
        if has_images:
            last_user = chat_messages[-1]
            if last_user.get("role") == "user":
                content: list = [{"type": "text", "text": last_user["content"]}]
                for image_data_uri in images:
                    content.append({"type": "image_url", "image_url": {"url": image_data_uri}})
                chat_messages[-1] = {"role": "user", "content": content}
        max_tokens = self._vision_max_output_tokens if has_images else self._max_output_tokens
        return endpoint, chat_messages, chosen_model, max_tokens

    def generate_link_card(self, *, title: str | None, description: str | None, source_url: str) -> object:
        """Derive a single travel card's fields from a fetched note's metadata."""
        if (
            not self._base_url
            or not self._api_key
            or not self._model
            or not ai_base_url_is_allowed(self._base_url, allow_local_http=self._allow_local_http)
        ):
            raise AIIntegrationUnconfigured
        endpoint = self._base_url if self._base_url.endswith("/chat/completions") else f"{self._base_url}/chat/completions"
        system_prompt = (
            "Return JSON only, with exactly {kind, title, place, notes}. "
            "kind must be one of flight|hotel|activity. title is a concise 1..160 char card name. "
            "place is a short place name string or null. notes is a concise Chinese summary or null. "
            "Do not invent booking details, times, prices, or contact information."
        )
        user_text = json.dumps({
            "title": title,
            "description": description,
            "sourceUrl": source_url,
        }, ensure_ascii=False)
        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_text},
        ]
        return self._post_chat(endpoint, messages, model=self._model, max_tokens=self._max_output_tokens)

    def generate_wallet_card_scan(self, *, image: str, style_hint: str) -> object:
        """Transcribe one wallet-card photo into structured fields via the vision model.

        The photo is never stored; the call is stateless and returns only the
        model's JSON. ``style_hint`` biases type detection (auto/bankcard/
        ticket/id/other) but the model may still pick any known type.
        """
        if (
            not self._base_url
            or not self._api_key
            or not self._vision_model
            or not ai_base_url_is_allowed(self._base_url, allow_local_http=self._allow_local_http)
        ):
            raise AIIntegrationUnconfigured
        endpoint = self._base_url if self._base_url.endswith("/chat/completions") else f"{self._base_url}/chat/completions"
        system_prompt = (
            "You read a photo of a travel wallet card (bank card, ticket, ID, membership card, etc.) "
            "and transcribe its fields. Reply with JSON ONLY, with exactly "
            "{label, number, note, detectedType}. "
            "detectedType is one of bankcard|ticket|id|other. "
            "label is a concise Chinese label (e.g. 银行卡, 门票, 护照, 会员卡). "
            "number is the primary number/code printed on the item (card number, ticket or seat code, ID number); "
            "preserve digit groups exactly as printed. If the number is unreadable or absent, return an empty string. "
            "note is null or a short Chinese note (e.g. seat row, expiry date, issuer). "
            f"styleHint={style_hint}; prefer that type when the image is ambiguous. "
            "Never invent numbers; only transcribe what is visible. Never return a CVV, PIN, or the full PAN of a payment card — "
            "for bank cards transcribe at most the last four digits as number and note the issuer/network in note."
        )
        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": [
                {"type": "text", "text": "Extract the wallet card fields from this photo."},
                {"type": "image_url", "image_url": {"url": image}},
            ]},
        ]
        return self._post_chat(endpoint, messages, model=self._vision_model, max_tokens=self._vision_max_output_tokens)

    def generate_card_draft(self, *, kind: str, day_date: date, currency: str | None, messages: list[dict], images: list[str] | None = None, link_context: dict | None = None) -> object:
        """Run a stateless multi-turn conversation that drafts one travel card.

        The caller replays the full message history each turn; the server keeps
        none of it. The model is instructed to reply with JSON of the exact
        shape ``{"reply": str, "cardDraft": {...}|null}`` and to progressively
        collect the required fields for the card kind before setting cardDraft.

        ``link_context`` carries fetched public-note metadata (title,
        description, source URL and a server-hosted image path) when the latest
        user message referenced a supported link; it is surfaced to the model
        so the draft uses real content instead of guessing from a bare URL.
        """
        has_images = bool(images)
        chosen_model = (self._vision_model or self._model) if has_images else self._model
        if (
            not self._base_url
            or not self._api_key
            or not chosen_model
            or not ai_base_url_is_allowed(self._base_url, allow_local_http=self._allow_local_http)
        ):
            raise AIIntegrationUnconfigured
        endpoint = self._base_url if self._base_url.endswith("/chat/completions") else f"{self._base_url}/chat/completions"
        system_prompt = self._card_draft_system_prompt(kind=kind, day_date=day_date, currency=currency, link_context=link_context)
        chat_messages: list = [{"role": "system", "content": system_prompt}]
        for message in messages:
            chat_messages.append({"role": message["role"], "content": message["content"]})
        if has_images:
            last_user = chat_messages[-1]
            if last_user.get("role") == "user":
                content: list = [{"type": "text", "text": last_user["content"]}]
                for image_data_uri in images:
                    content.append({"type": "image_url", "image_url": {"url": image_data_uri}})
                chat_messages[-1] = {"role": "user", "content": content}
        return self._post_chat(
            endpoint,
            chat_messages,
            model=chosen_model,
            max_tokens=self._vision_max_output_tokens if has_images else self._max_output_tokens,
        )

    def generate_expense_draft(self, *, day_date: date, currency: str | None, messages: list[dict], images: list[str] | None = None) -> object:
        """Run a stateless multi-turn conversation that drafts one expense.

        Mirrors ``generate_card_draft`` but produces an expense (the trip's
        actual price) instead of a card. Receipt photos are attached to the
        last user message so a vision model can read the total amount.
        """
        has_images = bool(images)
        chosen_model = (self._vision_model or self._model) if has_images else self._model
        if (
            not self._base_url
            or not self._api_key
            or not chosen_model
            or not ai_base_url_is_allowed(self._base_url, allow_local_http=self._allow_local_http)
        ):
            raise AIIntegrationUnconfigured
        endpoint = self._base_url if self._base_url.endswith("/chat/completions") else f"{self._base_url}/chat/completions"
        system_prompt = self._expense_draft_system_prompt(day_date=day_date, currency=currency)
        chat_messages: list = [{"role": "system", "content": system_prompt}]
        for message in messages:
            chat_messages.append({"role": message["role"], "content": message["content"]})
        if has_images:
            last_user = chat_messages[-1]
            if last_user.get("role") == "user":
                content: list = [{"type": "text", "text": last_user["content"]}]
                for image_data_uri in images:
                    content.append({"type": "image_url", "image_url": {"url": image_data_uri}})
                chat_messages[-1] = {"role": "user", "content": content}
        return self._post_chat(
            endpoint,
            chat_messages,
            model=chosen_model,
            max_tokens=self._vision_max_output_tokens if has_images else self._max_output_tokens,
        )

    @staticmethod
    def _expense_draft_system_prompt(*, day_date: date, currency: str | None) -> str:
        currency_note = f" The currency is {currency}; amounts are integer minor units (e.g. cents; 100 = 1.00)." if currency else " Amounts are integer minor units."
        return (
            "You are a travel expense assistant. Reply with JSON ONLY, with exactly "
            "{\"reply\": string, \"expenseDraft\": object | null}. "
            "`reply` is a concise Chinese message to the user (ask for whatever is still missing, or summarize). "
            "`expenseDraft` is null while you still need required fields; once you have them, set it to the full object. "
            f"This expense is for the date {day_date.isoformat()} (use YYYY-MM-DD for occurredOn). "
            f"Required fields: amountMinor (positive integer minor units), category (one of transport|lodging|food|tickets|shopping|other), occurredOn (YYYY-MM-DD).{currency_note} "
            "expenseDraft fields: amountMinor, currency, category, occurredOn, note, cardId. "
            "When the user shares a receipt photo, read the TOTAL amount due and put it in amountMinor. "
            "Infer a sensible category from the merchant/item (e.g. restaurant -> food, taxi -> transport, hotel -> lodging, attraction ticket -> tickets). "
            "note is an optional short Chinese description (merchant or item name). cardId must always be null (the user chooses the linked card). "
            "Never invent an amount you cannot read; ask the user to confirm instead. Never invent payment or personal information."
        )

    @staticmethod
    def _card_draft_system_prompt(*, kind: str, day_date: date, currency: str | None, link_context: dict | None = None) -> str:
        required = {
            "activity": "place (POI name + address), startAt (activity time), priceMinor (price)",
            "flight": "bookingCode (flight number), fromAirport, toAirport, startAt (departure time), priceMinor (price)",
            "hotel": "place (hotel name + address), startAt (check-in), endAt (check-out), priceMinor (price)",
        }[kind]
        currency_note = f" Prices are in {currency} minor units (e.g. cents; 100 = 1.00)." if currency else " Prices are integer minor units."
        prompt = (
            "You are a travel card assistant. Reply with JSON ONLY, with exactly "
            "{\"reply\": string, \"cardDraft\": object | null}. "
            "`reply` is a concise Chinese message to the user (ask for whatever is still missing, or summarize the draft). "
            f"`cardDraft` is null while you still need required fields; once you have them, set it to the full card object. "
            f"This card is for the date {day_date.isoformat()}. Use ISO 8601 datetime with timezone for startAt/endAt "
            f"(e.g. {day_date.isoformat()}T09:00:00Z). Required fields for a {kind} card: {required}.{currency_note} "
            "cardDraft fields: kind, title, startAt, endAt, place{name,address,latitude,longitude,placeId,cityCode}, "
            "bookingCode, fromAirport, toAirport, priceMinor, url, description, images, notes. "
            "Generate helpful values for non-required fields when you can: a concise title, a Chinese description/intro, "
            "a public HTTPS url if known, and notes. Do not invent images; leave images null unless given real paths. "
            "place must be an object with at least name and address for activity/hotel. fromAirport/toAirport only for flights. "
            "Never invent booking details beyond the flight number, and never invent contact or payment information."
        )
        if link_context:
            # Surface the fetched public note so the draft reflects real content.
            # The hosted image path is server-owned and may be placed in images.
            prompt += (
                "\n\nA public note was fetched from the link in the latest user message and may be used as a source: "
                f"sourceUrl={link_context.get('sourceUrl')}, title={link_context.get('title')}, "
                f"description={link_context.get('description')}, "
                f"hostedImagePath={link_context.get('imagePath')}. "
                "Prefer this real content for title/description/url/notes when relevant. "
                "Set cardDraft.url to the sourceUrl. "
                "If hostedImagePath is present, include it in cardDraft.images (the route guarantees it, but list it anyway)."
            )
        return prompt

    def _post_itinerary_chat_with_poi_tool(self, endpoint: str, messages: list, *, model: str, max_tokens: int, poi_search) -> object:
        tools = [{"type": "function", "function": {"name": "search_destination_pois", "description": "Search Apple Maps for real POIs inside the trip destination fence. Call this before every hotel or activity card.", "parameters": {"type": "object", "properties": {"query": {"type": "string", "description": "A concrete local-language or English POI, hotel, restaurant, attraction, or station name."}}, "required": ["query"], "additionalProperties": False}}}]
        tool_messages = list(messages)
        for attempt in range(1, 7):
            _logger.warning("ai_poi_tool model_turn=%s status=requesting_completion", attempt)
            message = self._post_chat_message(endpoint, tool_messages, model=model, max_tokens=max_tokens, tools=tools)
            tool_calls = message.get("tool_calls") if isinstance(message, dict) else None
            _logger.info(
                "ai_poi_tool model_turn=%s content=%r tool_calls=%r",
                attempt,
                message.get("content") if isinstance(message, dict) else None,
                tool_calls,
            )
            if not isinstance(tool_calls, list) or not tool_calls:
                content = message.get("content") if isinstance(message, dict) else None
                if not isinstance(content, str):
                    raise AIInvalidOutputError("tool completion missing content")
                _logger.warning("ai_poi_tool model_turn=%s final_content=%r", attempt, content)
                try:
                    return chat_output_from_text(content)
                except AIInvalidOutputError:
                    return _extract_json(content)
            tool_messages.append({"role": "assistant", "content": message.get("content") or "", "tool_calls": tool_calls})
            for call in tool_calls:
                function = call.get("function") if isinstance(call, dict) else None
                call_id = call.get("id") if isinstance(call, dict) else None
                if not isinstance(function, dict) or function.get("name") != "search_destination_pois" or not isinstance(call_id, str):
                    raise AIInvalidOutputError("unsupported tool")
                try:
                    arguments = json.loads(function.get("arguments") or "{}")
                    query = arguments.get("query")
                    if not isinstance(query, str) or not 2 <= len(query.strip()) <= 160:
                        raise ValueError
                    normalized_query = query.strip()
                    _logger.warning("ai_poi_tool model_turn=%s apple_request query=%r", attempt, normalized_query)
                    candidates = poi_search(normalized_query)
                except (TypeError, ValueError, json.JSONDecodeError) as exc:
                    _logger.warning("ai_poi_tool model_turn=%s invalid_tool_arguments error=%r", attempt, exc)
                    candidates = []
                _logger.warning("ai_poi_tool model_turn=%s apple_response candidates=%r", attempt, candidates)
                tool_messages.append({"role": "tool", "tool_call_id": call_id, "content": json.dumps({"candidates": candidates}, ensure_ascii=False)})
        raise AIInvalidOutputError("tool call limit exceeded")

    def _post_chat_message(self, endpoint: str, messages: list, *, model: str, max_tokens: int, tools: list) -> dict:
        request_payload = {"model": model, "temperature": 0.2, "max_tokens": max_tokens, "messages": messages, "tools": tools, "tool_choice": "auto"}
        request = Request(endpoint, data=json.dumps(request_payload, ensure_ascii=False).encode("utf-8"), headers={"Authorization": f"Bearer {self._api_key}", "Content-Type": "application/json"}, method="POST")
        try:
            _logger.warning("ai_poi_tool provider_request model=%s message_count=%s", model, len(messages))
            with build_opener(_NoRedirectHandler()).open(request, timeout=self._timeout_seconds) as response:
                payload = json.loads(response.read(512 * 1024))
            message = payload["choices"][0]["message"]
            if not isinstance(message, dict):
                raise TypeError
            return message
        except (HTTPError, URLError, TimeoutError, OSError, KeyError, IndexError, TypeError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise AIProviderError from exc

    def _post_chat_text(self, endpoint: str, messages: list, *, model: str, max_tokens: int) -> str:
        """POST a chat completion and return the raw assistant text."""
        request_payload = {
            "model": model,
            "temperature": 0.2,
            "max_tokens": max_tokens,
            "messages": messages,
        }
        request = Request(
            endpoint,
            data=json.dumps(request_payload, ensure_ascii=False).encode("utf-8"),
            headers={"Authorization": f"Bearer {self._api_key}", "Content-Type": "application/json"},
            method="POST",
        )
        try:
            # A configured HTTPS endpoint can still issue a redirect. Following
            # it would risk forwarding the bearer key to a different host.
            with build_opener(_NoRedirectHandler()).open(request, timeout=self._timeout_seconds) as response:
                raw_response = response.read(512 * 1024)
        except (HTTPError, URLError, TimeoutError, OSError) as exc:
            raise AIProviderError from exc
        try:
            response_payload = json.loads(raw_response)
            content = response_payload["choices"][0]["message"]["content"]
            if not isinstance(content, str):
                raise TypeError
            return content
        except (KeyError, IndexError, TypeError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise AIInvalidOutputError from exc

    def _post_chat(self, endpoint: str, messages: list, *, model: str, max_tokens: int) -> object:
        try:
            return _extract_json(self._post_chat_text(endpoint, messages, model=model, max_tokens=max_tokens))
        except json.JSONDecodeError as exc:
            raise AIInvalidOutputError from exc

    def _post_chat_stream(self, endpoint: str, messages: list, *, model: str, max_tokens: int):
        """Stream an OpenAI-compatible chat completion.

        Yields ``{"type": "reply", "text": str}`` for the new portion of the
        ``reply`` string as it becomes visible, then a single
        ``{"type": "output", "value": ...}`` with the full parsed payload. The
        upstream SSE is consumed line by line so reply text reaches the client
        while the model is still generating.
        """
        request_payload = {
            "model": model,
            "temperature": 0.2,
            "max_tokens": max_tokens,
            "messages": messages,
            "stream": True,
        }
        request = Request(
            endpoint,
            data=json.dumps(request_payload, ensure_ascii=False).encode("utf-8"),
            headers={"Authorization": f"Bearer {self._api_key}", "Content-Type": "application/json", "Accept": "text/event-stream"},
            method="POST",
        )
        try:
            response = build_opener(_NoRedirectHandler()).open(request, timeout=self._timeout_seconds)
        except (HTTPError, URLError, TimeoutError, OSError) as exc:
            raise AIProviderError from exc
        accumulated = ""
        consumed = 0
        legacy_mode: bool | None = None
        legacy_sent_len = 0
        try:
            for raw_line in response:
                try:
                    line = raw_line.decode("utf-8")
                except UnicodeDecodeError:
                    continue
                line = line.rstrip("\r\n")
                if not line or not line.startswith("data:"):
                    continue
                payload = line[5:].lstrip()
                if payload == "[DONE]":
                    break
                try:
                    chunk = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                delta = None
                try:
                    delta = chunk["choices"][0]["delta"].get("content")
                except (KeyError, IndexError, TypeError, AttributeError):
                    pass
                if not isinstance(delta, str) or not delta:
                    continue
                accumulated += delta
                if legacy_mode is None:
                    legacy_mode = _detect_legacy_stream(_strip_code_fences(accumulated).lstrip())
                if legacy_mode is None:
                    continue  # not enough tokens yet to classify the format
                if legacy_mode:
                    visible, _ = _reply_visible(accumulated)
                    if len(visible) > legacy_sent_len:
                        yield {"type": "reply", "text": visible[legacy_sent_len:]}
                        legacy_sent_len = len(visible)
                    continue
                objs, consumed = _parse_chat_lines(_strip_code_fences(accumulated), final=False, start=consumed)
                for obj in objs:
                    event = _chat_stream_event(obj)
                    if event:
                        yield event
        except (HTTPError, URLError, TimeoutError, OSError) as exc:
            raise AIProviderError from exc
        finally:
            try:
                response.close()
            except Exception:
                pass
        if legacy_mode is None:
            if not accumulated.strip():
                # Upstream completed without any assistant content (provider
                # error payload or empty choices), which is not parseable AI
                # output and should be reported as a provider failure.
                _logger.warning("ai stream carried no content")
                raise AIProviderError("upstream stream carried no content")
            legacy_mode = _detect_legacy_stream(_strip_code_fences(accumulated).lstrip())
            if legacy_mode is None:
                # Truncated stream that never reached a classifiable length.
                _logger.warning("ai stream truncated before format detection, head=%r", accumulated[:200])
                raise AIInvalidOutputError("stream truncated")
        if legacy_mode:
            try:
                output = _extract_json(accumulated)
            except json.JSONDecodeError as exc:
                _logger.warning("ai legacy output unparseable, head=%r", accumulated[:200])
                raise AIInvalidOutputError from exc
            yield {"type": "output", "value": output}
            return
        objs, _ = _parse_chat_lines(_strip_code_fences(accumulated), final=True)
        try:
            output = chat_output_from_lines(objs)
        except AIInvalidOutputError:
            _logger.warning("ai ndjson output unparseable, head=%r", accumulated[:200])
            raise
        yield {"type": "output", "value": output}


def _detect_legacy_stream(stripped: str) -> bool | None:
    """Classify the upstream format, or ``None`` when still ambiguous.

    Token-by-token deltas mean the first chunk may be just ``{"`` or ``{"t``;
    classifying on that prefix would misread NDJSON as a legacy JSON object.
    NDJSON lines start with ``{"t"`` — wait until the prefix either matches or
    provably diverges.
    """
    if not stripped:
        return None
    signature = '{"t"'
    if stripped.startswith(signature):
        return False
    if signature.startswith(stripped):
        return None
    return True


def _parse_chat_line(segment: str) -> dict | None:
    try:
        obj = json.loads(segment)
    except json.JSONDecodeError:
        return None
    return obj if isinstance(obj, dict) and isinstance(obj.get("t"), str) else None


def _parse_chat_lines(content: str, *, final: bool, start: int = 0) -> tuple[list[dict], int]:
    """Parse complete NDJSON lines from ``content[start:]``.

    Only newline-terminated lines are consumed while streaming; the trailing
    partial line is left for the next chunk. With ``final=True`` the tail is
    parsed too. Returns the parsed objects and the new offset.
    """
    objs: list[dict] = []
    pos = start
    while pos <= len(content):
        newline = content.find("\n", pos)
        if newline == -1:
            if final:
                tail = content[pos:].strip()
                if tail:
                    obj = _parse_chat_line(tail)
                    if obj is not None:
                        objs.append(obj)
                pos = len(content)
            break
        segment = content[pos:newline].strip()
        pos = newline + 1
        if not segment:
            continue
        obj = _parse_chat_line(segment)
        if obj is not None:
            objs.append(obj)
    return objs, pos


def _chat_stream_event(obj: dict) -> dict | None:
    """Map one NDJSON line to a stream event for the routes layer."""
    kind = obj["t"]
    if kind in ("think", "reply") and isinstance(obj.get("d"), str) and obj["d"]:
        return {"type": "thinking" if kind == "think" else "reply", "text": obj["d"]}
    if kind == "card":
        return {"type": "card", "value": {key: value for key, value in obj.items() if key != "t"}}
    if kind == "cardx":
        return {"type": "cardx", "value": {key: value for key, value in obj.items() if key != "t"}}
    return None


def chat_output_from_lines(objs: list[dict]) -> dict:
    """Assemble the final ``{reply, cards}`` payload from parsed NDJSON lines.

    Each ``cardx`` line extends the most recent ``card`` line. Raises
    ``AIInvalidOutputError`` when nothing usable was produced.
    """
    reply_parts: list[str] = []
    cards: list[dict] = []
    for obj in objs:
        kind = obj["t"]
        if kind == "reply" and isinstance(obj.get("d"), str):
            reply_parts.append(obj["d"])
        elif kind == "card":
            cards.append({key: value for key, value in obj.items() if key != "t"})
        elif kind == "cardx" and cards:
            cards[-1].update({key: value for key, value in obj.items() if key != "t"})
    if not reply_parts and not cards:
        raise AIInvalidOutputError("no reply or cards in NDJSON output")
    return {"reply": "".join(reply_parts), "cards": cards}


def chat_output_from_text(content: str) -> dict:
    objs, _ = _parse_chat_lines(_strip_code_fences(content), final=True)
    return chat_output_from_lines(objs)


def _strip_code_fences(content: str) -> str:
    """Remove markdown code fences some models wrap NDJSON/JSON output in."""
    text = content
    stripped = text.lstrip()
    if stripped.startswith("```"):
        first_newline = stripped.find("\n")
        if first_newline != -1:
            body = stripped[first_newline + 1:]
            closing = body.rfind("```")
            return body[:closing] if closing != -1 else body
    return text


def _extract_json(content: str) -> object:
    """Parse a JSON object from a chat completion, tolerating prose and fences.

    Models frequently wrap JSON in markdown code fences or add conversational
    framing despite the "JSON only" instruction. We try, in order: a direct
    parse, stripping a single surrounding code fence, and salvaging the
    outermost ``{...}`` embedded in prose. Anything still unparseable raises
    ``json.JSONDecodeError`` so the caller maps it to a stable 422.
    """
    text = content.strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    fence = re.search(r"```(?:json)?\s*(\{.*\})\s*```", text, re.DOTALL)
    if fence:
        try:
            return json.loads(fence.group(1))
        except json.JSONDecodeError:
            pass
    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end > start:
        return json.loads(text[start:end + 1])
    raise json.JSONDecodeError("no JSON object found", text, 0)


def _reply_visible(content: str) -> tuple[str, bool]:
    """Return the decoded ``reply`` string visible so far in a partial JSON.

    The itinerary chat model emits ``{"reply": "...", "cards": [...]}``. To
    stream the reply before the JSON is complete, this scans the buffered
    content for the ``"reply"`` key and decodes its string value up to the
    point the buffer currently reaches. A trailing incomplete escape (a lone
    ``\\`` or partial ``\\uXXXX``) is held back so the returned prefix only
    contains characters that are final. The second return value is ``True`` when
    the closing quote was reached (the reply string is fully present).

    Re-scanning the whole buffer each call is fine: replies are short, and the
    decoded prefix is monotonic, so the caller can safely diff against what it
    already emitted.
    """
    key_index = content.find('"reply"')
    if key_index == -1:
        return "", False
    pos = key_index + len('"reply"')
    length = len(content)
    while pos < length and content[pos] in " \t\r\n:":
        pos += 1
    if pos >= length or content[pos] != '"':
        return "", False
    pos += 1  # past the opening quote
    decoded: list[str] = []
    complete = False
    while pos < length:
        char = content[pos]
        if char == "\\":
            if pos + 1 >= length:
                break  # lone backslash — wait for the escape to complete
            esc = content[pos + 1]
            if esc == "u":
                if pos + 6 > length:
                    break  # partial \uXXXX — hold back
                try:
                    decoded.append(chr(int(content[pos + 2:pos + 6], 16)))
                except ValueError:
                    decoded.append(esc)
                pos += 6
            else:
                decoded.append({
                    "n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "/": "/",
                }.get(esc, esc))
                pos += 2
            continue
        if char == '"':
            complete = True
            break
        decoded.append(char)
        pos += 1
    return "".join(decoded), complete
