# Icon Manifest

## Scope and use policy

- This manifest covers the confirmed MVP UI: single itinerary, travel cards, external sharing, map routing, expenses, local-only wallet, AI draft import, and sync feedback.
- Use the semantic icon IDs below consistently. The SwiftUI implementation may render the matching SF Symbol where one exists; this document is the canonical fallback/source reference for any exported SVG.
- Do not download, commit, or hotlink a third-party brand asset unless the corresponding feature is implemented. A text label is the default for Fliggy and AMap actions; their logos are not required to make an OS share sheet, a public URL, or a map deeplink work.
- Icons are decorative only where a text label is present. Interactive controls need an accessibility label describing the action, not the icon name.

## UI icons

All icons in this table are [Lucide Static](https://lucide.dev/), released under the [ISC License](https://github.com/lucide-icons/lucide/blob/main/LICENSE). Version-pinned URLs keep the rendered SVG stable.

| Purpose | Icon ID | SVG URL | Source | License |
| --- | --- | --- | --- | --- |
| Itinerary tab and date grouping | `calendar-days` | https://unpkg.com/lucide-static@0.468.0/icons/calendar-days.svg | Lucide Static | ISC |
| Previous/next date navigation | `chevron-left`, `chevron-right` | https://unpkg.com/lucide-static@0.468.0/icons/chevron-left.svg · https://unpkg.com/lucide-static@0.468.0/icons/chevron-right.svg | Lucide Static | ISC |
| Add card, day, expense, or wallet item | `circle-plus` | https://unpkg.com/lucide-static@0.468.0/icons/circle-plus.svg | Lucide Static | ISC |
| Edit an existing resource | `pencil` | https://unpkg.com/lucide-static@0.468.0/icons/pencil.svg | Lucide Static | ISC |
| Delete with confirmation | `trash-2` | https://unpkg.com/lucide-static@0.468.0/icons/trash-2.svg | Lucide Static | ISC |
| Overflow/more actions | `ellipsis` | https://unpkg.com/lucide-static@0.468.0/icons/ellipsis.svg | Lucide Static | ISC |
| Flight card kind | `plane` | https://unpkg.com/lucide-static@0.468.0/icons/plane.svg | Lucide Static | ISC |
| Hotel card kind | `hotel` | https://unpkg.com/lucide-static@0.468.0/icons/hotel.svg | Lucide Static | ISC |
| Activity/attraction card kind | `map-pinned` | https://unpkg.com/lucide-static@0.468.0/icons/map-pinned.svg | Lucide Static | ISC |
| Place/address row | `map-pin` | https://unpkg.com/lucide-static@0.468.0/icons/map-pin.svg | Lucide Static | ISC |
| Time and time range | `clock-3` | https://unpkg.com/lucide-static@0.468.0/icons/clock-3.svg | Lucide Static | ISC |
| Saved public URL | `link` | https://unpkg.com/lucide-static@0.468.0/icons/link.svg | Lucide Static | ISC |
| Open a public link or browser fallback | `external-link` | https://unpkg.com/lucide-static@0.468.0/icons/external-link.svg | Lucide Static | ISC |
| Open the system share sheet | `share-2` | https://unpkg.com/lucide-static@0.468.0/icons/share-2.svg | Lucide Static | ISC |
| Copy booking code, number, or link | `copy` | https://unpkg.com/lucide-static@0.468.0/icons/copy.svg | Lucide Static | ISC |
| Successful save/copy/import state | `check` | https://unpkg.com/lucide-static@0.468.0/icons/check.svg | Lucide Static | ISC |
| Clear/cancel a sheet or field | `x` | https://unpkg.com/lucide-static@0.468.0/icons/x.svg | Lucide Static | ISC |
| Loading a remote request | `loader-circle` | https://unpkg.com/lucide-static@0.468.0/icons/loader-circle.svg | Lucide Static | ISC |
| Retry sync, AI, or route request | `refresh-cw` | https://unpkg.com/lucide-static@0.468.0/icons/refresh-cw.svg | Lucide Static | ISC |
| Offline/connection unavailable state | `wifi-off` | https://unpkg.com/lucide-static@0.468.0/icons/wifi-off.svg | Lucide Static | ISC |
| Pending local changes | `cloud-upload` | https://unpkg.com/lucide-static@0.468.0/icons/cloud-upload.svg | Lucide Static | ISC |
| Remote sync unavailable state | `cloud-off` | https://unpkg.com/lucide-static@0.468.0/icons/cloud-off.svg | Lucide Static | ISC |
| Two-person collaboration context | `users` | https://unpkg.com/lucide-static@0.468.0/icons/users.svg | Lucide Static | ISC |
| Device display name | `user-round` | https://unpkg.com/lucide-static@0.468.0/icons/user-round.svg | Lucide Static | ISC |
| Route summary | `route` | https://unpkg.com/lucide-static@0.468.0/icons/route.svg | Lucide Static | ISC |
| Open external navigation | `navigation` | https://unpkg.com/lucide-static@0.468.0/icons/navigation.svg | Lucide Static | ISC |
| Driving mode | `car` | https://unpkg.com/lucide-static@0.468.0/icons/car.svg | Lucide Static | ISC |
| Walking mode | `footprints` | https://unpkg.com/lucide-static@0.468.0/icons/footprints.svg | Lucide Static | ISC |
| Public-transit mode | `train-front` | https://unpkg.com/lucide-static@0.468.0/icons/train-front.svg | Lucide Static | ISC |
| AI entry point and generated-draft marker | `sparkles` | https://unpkg.com/lucide-static@0.468.0/icons/sparkles.svg | Lucide Static | ISC |
| Generate/re-generate an AI draft | `wand-sparkles` | https://unpkg.com/lucide-static@0.468.0/icons/wand-sparkles.svg | Lucide Static | ISC |
| AI source-text input | `file-text` | https://unpkg.com/lucide-static@0.468.0/icons/file-text.svg | Lucide Static | ISC |
| Confirm draft items as itinerary cards | `calendar-plus` | https://unpkg.com/lucide-static@0.468.0/icons/calendar-plus.svg | Lucide Static | ISC |
| Expenses tab and expense record | `receipt-text` | https://unpkg.com/lucide-static@0.468.0/icons/receipt-text.svg | Lucide Static | ISC |
| Expense category/filter | `tag` | https://unpkg.com/lucide-static@0.468.0/icons/tag.svg | Lucide Static | ISC |
| Expense amount | `banknote` | https://unpkg.com/lucide-static@0.468.0/icons/banknote.svg | Lucide Static | ISC |
| Category breakdown/statistics | `chart-bar` | https://unpkg.com/lucide-static@0.468.0/icons/chart-bar.svg | Lucide Static | ISC |
| Equal split indicator | `equal` | https://unpkg.com/lucide-static@0.468.0/icons/equal.svg | Lucide Static | ISC |
| Local wallet tab and wallet item | `wallet-cards` | https://unpkg.com/lucide-static@0.468.0/icons/wallet-cards.svg | Lucide Static | ISC |
| Reveal sensitive local number | `eye` | https://unpkg.com/lucide-static@0.468.0/icons/eye.svg | Lucide Static | ISC |
| Hide sensitive local number | `eye-off` | https://unpkg.com/lucide-static@0.468.0/icons/eye-off.svg | Lucide Static | ISC |
| On-device encryption/privacy explanation | `lock-keyhole` | https://unpkg.com/lucide-static@0.468.0/icons/lock-keyhole.svg | Lucide Static | ISC |
| Non-blocking warning or privacy notice | `circle-alert` | https://unpkg.com/lucide-static@0.468.0/icons/circle-alert.svg | Lucide Static | ISC |
| App/trip settings | `settings` | https://unpkg.com/lucide-static@0.468.0/icons/settings.svg | Lucide Static | ISC |

## Brand and integration treatment

| Integration | Display treatment | Icon ID / SVG URL | Source | License / usage note |
| --- | --- | --- | --- | --- |
| 小红书 (Xiaohongshu) | Optional icon beside the explicit `小红书` action label; do not rely on the logo alone. | `simple-icons:xiaohongshu` · https://cdn.simpleicons.org/xiaohongshu | [Simple Icons](https://simpleicons.org/?q=xiaohongshu) | [CC0 1.0](https://github.com/simple-icons/simple-icons/blob/develop/LICENSE.md) for the SVG artwork; the 小红书 name/logo remains its owner’s trademark. |
| 飞猪 (Fliggy) | Use the explicit `飞猪` label plus `external-link` or the system `share-2` action. No logo asset is bundled. | `external-link` · https://unpkg.com/lucide-static@0.468.0/icons/external-link.svg | Lucide Static | ISC; avoids unverified third-party logo reuse. |
| 高德地图 (AMap) | Use the explicit `高德地图` label plus `navigation`; use `route` for the estimate itself. No logo asset is bundled. | `navigation` · https://unpkg.com/lucide-static@0.468.0/icons/navigation.svg | Lucide Static | ISC; map deeplink and web fallback do not require a brand logo. |
| iOS system sharing | Present the system share sheet with its native label and `share-2` fallback. | `share-2` · https://unpkg.com/lucide-static@0.468.0/icons/share-2.svg | Lucide Static | ISC; do not reproduce Apple marks. |

## Visual constraints

- Use one outline weight and a single semantic tint system; card kind must also have a text label, so color is never the only differentiator.
- Use 20–24 pt icons in standard controls and retain a 44 pt minimum hit target.
- The list-card swipe actions map edit to `icon-edit-outline`, Agent chat to the user-provided local vector `icon-chat-outline`, and delete to `icon-delete-outline` (`trash-2`); all render as white templates over semantic gray/orange/red action fills.
- Do not use emoji as replacements for any icon listed here.
- Do not show third-party logos as an endorsement or imply private API access; the integration actions only open saved public links, a browser fallback, or the iOS share sheet.
