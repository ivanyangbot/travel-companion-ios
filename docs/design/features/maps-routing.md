# Feature Implementation: 地图、距离与路线

## Goal
为有坐标的景点卡片提供高德距离、预计时长与一键外部路线；不在 App 内导航。

## Files
- Create: iOS `Features/Maps/{PlaceSearchView,RouteSheet,MapLinkHandler}.swift`、`Data/RouteCache.swift`；后端 `app/routes/maps.py`、`app/services/amap.py`、`tests/test_maps.py`。
- Modify: iOS 卡片编辑页、`Core/APIClient.swift`；后端 `app/__init__.py`、`app/config.py`。

## Tasks

### Task 1: 高德代理和地点数据
- Files: `app/routes/maps.py`、`app/services/amap.py`、`app/schemas.py`、`tests/test_maps.py`。
- Implementation: `GET /v1/places/search?keyword=&city=` 返回标准化 `Place` 候选；`POST /v1/routes/estimate` 接收 origin/destination 经纬度和 `walking|driving|transit`，由环境变量 `AMAP_WEB_SERVICE_KEY` 调用高德并转换为距离、秒数和更新时间。密钥不进 iOS 或日志。
- Verification: pytest 模拟供应商成功、配额/超时与非法坐标；无 Key 时返回可理解的 `503 integration_unconfigured`。

### Task 2: 客户端路线体验
- Files: `PlaceSearchView.swift`、`RouteSheet.swift`、`MapLinkHandler.swift`、`RouteCache.swift`。
- Implementation: 选择地点时保存名称/地址/坐标；按起终点+方式在 SwiftData 缓存 15 分钟。路线 Sheet 展示来源和更新时间；用高德 URL Scheme 打开路线，`canOpenURL` 失败改用网页 URL。 
- Verification: 单元测试缓存失效和 URL 组装；真机选两地验证高德 App 与网页回退。

## API/Data Changes
- `Place={id,name,address,latitude,longitude,amapId}` 作为共享卡片的可选字段；`RouteEstimate` 只在本机缓存、不落 PostgreSQL。
- 地图请求无卡包字段；公共 API 无认证但仍校验坐标范围、关键字长度与方式枚举。

## Edge Cases
- 任一地点无坐标时禁用估算并提供“搜索地点”入口。
- 高德限流、无网络或返回空路线时保留旧缓存并显示来源/过期状态，不能虚构时长。

## Human Verification
- 对两个真实地点分别测试步行和驾车，核对距离/时长可显示，并测试未装高德时网页能打开起终点。

## Done Criteria
- 地点可搜索并保存；有坐标的两点可得到结果或明确错误，且外部路线总有可用回退。
