# Fingerprint comparison

| | candidate | reference | control |
|---|---|---|---|
| engine | `lightpanda` | `chrome-headless-ua` | `chrome-headed` |
| build | `1.0.0-dev.788+6d57e9ce9` | `Chrome/151.0.7922.172` | `Chrome/151.0.7922.172` |

## 1. JS fingerprint surface

70/90 probe keys identical to the reference.

Of the 20 that are not, 12 land where the two
references disagree (➖ — not a requirement), leaving **8** where every
accepted browser agrees and this engine does not:

- `navigator.hardwareConcurrency`
- `navigator.deviceMemory`
- `navigator.ownPropertyNames`
- `window.screenX`
- `canvas.toDataURL.fingerprint`
- `fonts.widths`
- `matchMedia.dark`
- `window.ownPropertyNames.count`

| | key | candidate | reference (real Chrome) | control |
|---|---|---|---|---|
| ✅ | `navigator.userAgent` | `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari…` | `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari…` | `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari…` |
| ✅ | `navigator.appCodeName` | `Mozilla` | `Mozilla` | `Mozilla` |
| ✅ | `navigator.appName` | `Netscape` | `Netscape` | `Netscape` |
| ✅ | `navigator.appVersion` | `5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36` | `5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36` | `5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36` |
| ✅ | `navigator.platform` | `MacIntel` | `MacIntel` | `MacIntel` |
| ✅ | `navigator.product` | `Gecko` | `Gecko` | `Gecko` |
| ✅ | `navigator.productSub` | `20030107` | `20030107` | `20030107` |
| ✅ | `navigator.vendor` | `Google Inc.` | `Google Inc.` | `Google Inc.` |
| ✅ | `navigator.vendorSub` | `` | `` | `` |
| ✅ | `navigator.oscpu` | ⚠️ `undefined` | ⚠️ `undefined` | ⚠️ `undefined` |
| ✅ | `navigator.language` | `en-US` | `en-US` | `en-US` |
| ✅ | `navigator.languages` | `["en-US","en"]` | `["en-US","en"]` | `["en-US","en"]` |
| ❌ | `navigator.hardwareConcurrency` | `8` | `10` | `10` |
| ❌ | `navigator.deviceMemory` | `8` | `16` | `16` |
| ✅ | `navigator.maxTouchPoints` | `0` | `0` | `0` |
| ✅ | `navigator.webdriver` | `false` | `false` | `false` |
| ✅ | `navigator.pdfViewerEnabled` | `true` | `true` | `true` |
| ✅ | `navigator.cookieEnabled` | `true` | `true` | `true` |
| ✅ | `navigator.doNotTrack` | `null` | `null` | `null` |
| ✅ | `navigator.onLine` | `true` | `true` | `true` |
| ❌ | `navigator.ownPropertyNames` | `["adAuctionComponents","appCodeName","appName","appVersion","bluetooth","canLoadAdAuctionFencedFrame","canShar…` | `["adAuctionComponents","appCodeName","appName","appVersion","bluetooth","canLoadAdAuctionFencedFrame","canShar…` | `["adAuctionComponents","appCodeName","appName","appVersion","bluetooth","canLoadAdAuctionFencedFrame","canShar…` |
| ✅ | `navigator.plugins.length` | `5` | `5` | `5` |
| ✅ | `navigator.plugins.names` | `["PDF Viewer","Chrome PDF Viewer","Chromium PDF Viewer","Microsoft Edge PDF Viewer","WebKit built-in PDF"]` | `["PDF Viewer","Chrome PDF Viewer","Chromium PDF Viewer","Microsoft Edge PDF Viewer","WebKit built-in PDF"]` | `["PDF Viewer","Chrome PDF Viewer","Chromium PDF Viewer","Microsoft Edge PDF Viewer","WebKit built-in PDF"]` |
| ✅ | `navigator.mimeTypes.length` | `2` | `2` | `2` |
| ✅ | `navigator.userAgentData.brands` | `[{"brand":"Not=A?Brand","version":"99"},{"brand":"Google Chrome","version":"151"},{"brand":"Chromium","version…` | `[{"brand":"Not=A?Brand","version":"99"},{"brand":"Google Chrome","version":"151"},{"brand":"Chromium","version…` | `[{"brand":"Not=A?Brand","version":"99"},{"brand":"Google Chrome","version":"151"},{"brand":"Chromium","version…` |
| ✅ | `navigator.userAgentData.mobile` | `false` | `false` | `false` |
| ✅ | `navigator.userAgentData.platform` | `macOS` | `macOS` | `macOS` |
| ➖ | `navigator.userAgentData.highEntropy` | `{"brands":[{"brand":"Not=A?Brand","version":"99"},{"brand":"Google Chrome","version":"151"},{"brand":"Chromium…` | `{"architecture":"","bitness":"","brands":[{"brand":"Not=A?Brand","version":"99"},{"brand":"Google Chrome","ver…` | `{"architecture":"arm","bitness":"64","brands":[{"brand":"Not=A?Brand","version":"99"},{"brand":"Google Chrome"…` |
| ✅ | `navigator.permissions.notifications` | `prompt` | `prompt` | `prompt` |
| ➖ | `navigator.connection` | `{"effectiveType":"4g","rtt":100,"downlink":1.45,"saveData":false}` | `{"effectiveType":"4g","rtt":150,"downlink":1.75,"saveData":false}` | `{"effectiveType":"4g","rtt":100,"downlink":1.7,"saveData":false}` |
| ✅ | `navigator.mediaDevices` | `function` | `function` | `function` |
| ✅ | `navigator.getBattery` | `function` | `function` | `function` |
| ✅ | `navigator.storage.estimate` | `number` | `number` | `number` |
| ✅ | `window.chrome` | `object` | `object` | `object` |
| ✅ | `window.chrome.keys` | `["app","csi","loadTimes"]` | `["app","csi","loadTimes"]` | `["app","csi","loadTimes"]` |
| ✅ | `window.chrome.runtime` | `undefined` | `undefined` | `undefined` |
| ✅ | `window.chrome.csi` | `function` | `function` | `function` |
| ✅ | `window.chrome.loadTimes` | `function` | `function` | `function` |
| ✅ | `window.chrome.app.isInstalled` | `false` | `false` | `false` |
| ✅ | `tell.cdc_props` | `[]` | `[]` | `[]` |
| ✅ | `tell.documentElement.webdriver` | `null` | `null` | `null` |
| ✅ | `tell.eval.toString.length` | `33` | `33` | `33` |
| ✅ | `tell.Function.toString.native` | `function toString() { [native code] }` | `function toString() { [native code] }` | `function toString() { [native code] }` |
| ✅ | `tell.navigator.toStringTag` | `[object Navigator]` | `[object Navigator]` | `[object Navigator]` |
| ✅ | `tell.error.stack.shape` | `TypeError: Cannot read properties of null (reading 'f') \|     at <anonymous>:74:18 \|     at get (<anonymous>:1…` | `TypeError: Cannot read properties of null (reading 'f') \|     at <anonymous>:74:18 \|     at get (<anonymous>:1…` | `TypeError: Cannot read properties of null (reading 'f') \|     at <anonymous>:74:18 \|     at get (<anonymous>:1…` |
| ✅ | `tell.Notification.permission` | `default` | `default` | `default` |
| ✅ | `tell.outerdim.zero` | `false` | `false` | `false` |
| ➖ | `screen.width` | `1920` | `800` | `1512` |
| ➖ | `screen.height` | `1080` | `600` | `982` |
| ➖ | `screen.availWidth` | `1920` | `800` | `1512` |
| ➖ | `screen.availHeight` | `1040` | `600` | `949` |
| ✅ | `screen.availLeft` | `0` | `0` | `0` |
| ➖ | `screen.availTop` | `40` | `0` | `33` |
| ✅ | `screen.colorDepth` | `24` | `24` | `30` |
| ✅ | `screen.pixelDepth` | `24` | `24` | `30` |
| ✅ | `screen.orientation` | `{"type":"landscape-primary","angle":0}` | `{"type":"landscape-primary","angle":0}` | `{"type":"landscape-primary","angle":0}` |
| ➖ | `window.innerWidth` | `1920` | `756` | `1200` |
| ➖ | `window.innerHeight` | `1080` | `469` | `818` |
| ➖ | `window.outerWidth` | `1920` | `756` | `1200` |
| ➖ | `window.outerHeight` | `1080` | `556` | `905` |
| ✅ | `window.devicePixelRatio` | `1` | `1` | `2` |
| ❌ | `window.screenX` | `0` | `22` | `22` |
| ➖ | `window.screenY` | `0` | `22` | `55` |
| ✅ | `window.toolbar.visible` | `true` | `true` | `true` |
| ✅ | `intl.timeZone` | `America/Los_Angeles` | `America/Los_Angeles` | `America/Los_Angeles` |
| ✅ | `intl.locale` | `en-US` | `en-US` | `en-US` |
| ✅ | `date.timezoneOffset` | `480` | `480` | `480` |
| ✅ | `date.toString` | `Wed Dec 31 1969 16:00:00 GMT-0800 (Pacific Standard Time)` | `Wed Dec 31 1969 16:00:00 GMT-0800 (Pacific Standard Time)` | `Wed Dec 31 1969 16:00:00 GMT-0800 (Pacific Standard Time)` |
| ✅ | `canvas.getContext2d` | `object` | `object` | `object` |
| ✅ | `canvas.toDataURL.type` | `function` | `function` | `function` |
| ❌ | `canvas.toDataURL.fingerprint` | `{"len":370,"prefix":"data:image/png;base64,iVBORw0K","hash":-546904589}` | `{"len":7614,"prefix":"data:image/png;base64,iVBORw0K","hash":725900497}` | `{"len":7614,"prefix":"data:image/png;base64,iVBORw0K","hash":725900497}` |
| ✅ | `canvas.getImageData.nonzero` | `{"first4":[255,0,0,255],"anyNonZero":true}` | `{"first4":[255,0,0,255],"anyNonZero":true}` | `{"first4":[255,0,0,255],"anyNonZero":true}` |
| ✅ | `canvas.measureText` | `89.9658203125` | `89.9658203125` | `89.9658203125` |
| ✅ | `webgl.getContext.webgl` | `ok` | `ok` | `ok` |
| ✅ | `webgl.getContext.webgl2` | `ok` | `ok` | `ok` |
| ✅ | `webgl.getContext.experimental-webgl` | `ok` | `ok` | `ok` |
| ✅ | `webgl.params` | `{"VENDOR":"WebKit","RENDERER":"WebKit WebGL","VERSION":"WebGL 1.0 (OpenGL ES 2.0 Chromium)","SHADING_LANGUAGE_…` | `{"VENDOR":"WebKit","RENDERER":"WebKit WebGL","VERSION":"WebGL 1.0 (OpenGL ES 2.0 Chromium)","SHADING_LANGUAGE_…` | `{"VENDOR":"WebKit","RENDERER":"WebKit WebGL","VERSION":"WebGL 1.0 (OpenGL ES 2.0 Chromium)","SHADING_LANGUAGE_…` |
| ✅ | `audio.AudioContext` | `function` | `function` | `function` |
| ✅ | `audio.sampleRate` | `48000` | `48000` | `48000` |
| ✅ | `audio.OfflineAudioContext` | `function` | `function` | `function` |
| ✅ | `fonts.api` | `function` | `function` | `function` |
| ❌ | `fonts.widths` | `{"monospace":564,"sans-serif":648,"serif":620,"Arial":648,"Helvetica Neue":662,"Times New Roman":620}` | `{"monospace":620,"sans-serif":620,"serif":620,"Arial":648,"Helvetica Neue":662,"Times New Roman":620}` | `{"monospace":620,"sans-serif":620,"serif":620,"Arial":648,"Helvetica Neue":662,"Times New Roman":620}` |
| ✅ | `media.canPlayType` | `{"h264":"probably","webm":"probably","ogg":""}` | `{"h264":"probably","webm":"probably","ogg":""}` | `{"h264":"probably","webm":"probably","ogg":""}` |
| ✅ | `rtc.RTCPeerConnection` | `function` | `function` | `function` |
| ✅ | `perf.memory` | `[]` | `[]` | `[]` |
| ✅ | `speech.voices.length` | `0` | `0` | `0` |
| ❌ | `matchMedia.dark` | `false` | `true` | `true` |
| ✅ | `matchMedia.coarsePointer` | `false` | `false` | `false` |
| ✅ | `matchMedia.hover` | `true` | `true` | `true` |
| ❌ | `window.ownPropertyNames.count` | `1203` | `1237` | `1237` |

## 2. HTTP request headers (local origin)

| path | candidate header order | reference header order | control |
|---|---|---|---|
| `/` | Host, Connection, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Sec-Ch-Ua-Platform, Upgrade-Insecure-Requests, User-Agent, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-User, Sec-Fetch-Dest, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua, sec-ch-ua-mobile, sec-ch-ua-platform, Upgrade-Insecure-Requests, User-Agent, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-User, Sec-Fetch-Dest, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua, sec-ch-ua-mobile, sec-ch-ua-platform, Upgrade-Insecure-Requests, User-Agent, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-User, Sec-Fetch-Dest, Accept-Encoding, Accept-Language |
| `/api/fetch` | Host, Connection, Sec-Ch-Ua-Platform, User-Agent, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/api/xhr` | Host, Connection, Sec-Ch-Ua-Platform, User-Agent, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/asset.css` | Host, Connection, Sec-Ch-Ua-Platform, User-Agent, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/asset.js` | Host, Connection, Sec-Ch-Ua-Platform, User-Agent, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/asset.png` | Host, Connection, Sec-Ch-Ua-Platform, User-Agent, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/favicon.ico` | Host, Connection, Sec-Ch-Ua-Platform, User-Agent, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/frame.html` | Host, Connection, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Sec-Ch-Ua-Platform, Upgrade-Insecure-Requests, User-Agent, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua, sec-ch-ua-mobile, sec-ch-ua-platform, Upgrade-Insecure-Requests, User-Agent, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua, sec-ch-ua-mobile, sec-ch-ua-platform, Upgrade-Insecure-Requests, User-Agent, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/nav` | Host, Connection, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Sec-Ch-Ua-Platform, Upgrade-Insecure-Requests, User-Agent, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-User, Sec-Fetch-Dest, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua, sec-ch-ua-mobile, sec-ch-ua-platform, Upgrade-Insecure-Requests, User-Agent, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-User, Sec-Fetch-Dest, Accept-Encoding, Accept-Language | Host, Connection, sec-ch-ua, sec-ch-ua-mobile, sec-ch-ua-platform, Upgrade-Insecure-Requests, User-Agent, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-User, Sec-Fetch-Dest, Accept-Encoding, Accept-Language |

### Header values on the document request

| | header | candidate | reference | control |
|---|---|---|---|---|
| ➖ | `host` | `127.0.0.1:50414` | `127.0.0.1:49944` | `127.0.0.1:50038` |
| ✅ | `connection` | `keep-alive` | `keep-alive` | `keep-alive` |
| ✅ | `sec-ch-ua` | `"Not=A?Brand";v="99", "Google Chrome";v="151", "Chromium";v="151"` | `"Not=A?Brand";v="99", "Google Chrome";v="151", "Chromium";v="151"` | `"Not=A?Brand";v="99", "Google Chrome";v="151", "Chromium";v="151"` |
| ✅ | `sec-ch-ua-mobile` | `?0` | `?0` | `?0` |
| ✅ | `sec-ch-ua-platform` | `"macOS"` | `"macOS"` | `"macOS"` |
| ✅ | `upgrade-insecure-requests` | `1` | `1` | `1` |
| ✅ | `user-agent` | `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari…` | `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari…` | `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari…` |
| ✅ | `accept` | `text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/s…` | `text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/s…` | `text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/s…` |
| ✅ | `sec-fetch-site` | `none` | `none` | `none` |
| ✅ | `sec-fetch-mode` | `navigate` | `navigate` | `navigate` |
| ✅ | `sec-fetch-user` | `?1` | `?1` | `?1` |
| ✅ | `sec-fetch-dest` | `document` | `document` | `document` |
| ✅ | `accept-encoding` | `gzip, deflate, br, zstd` | `gzip, deflate, br, zstd` | `gzip, deflate, br, zstd` |
| ✅ | `accept-language` | `en-US,en;q=0.9` | `en-US,en;q=0.9` | `en-US,en;q=0.9` |

## 3. bot.sannysoft.com

Candidate FAIL rows: **0** — none

| | test | candidate | reference | control |
|---|---|---|---|---|
| ✅ | User Agent (Old) | pass · `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari…` | pass · `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari…` | pass · `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari…` |
| ✅ | WebDriver (New) | pass · `missing (passed)` | pass · `missing (passed)` | pass · `missing (passed)` |
| ✅ | WebDriver Advanced | pass · `passed` | pass · `passed` | pass · `passed` |
| ✅ | Chrome (New) | pass · `present (passed)` | pass · `present (passed)` | pass · `present (passed)` |
| ✅ | Permissions (New) | pass · `prompt` | pass · `prompt` | pass · `prompt` |
| ✅ | Plugins Length (Old) | pass · `5` | pass · `5` | pass · `5` |
| ✅ | Plugins is of type PluginArray | pass · `passed` | pass · `passed` | pass · `passed` |
| ✅ | Languages (Old) | pass · `en-US,en` | pass · `en-US,en` | pass · `en-US,en` |
| ✅ | WebGL Vendor | pass · `Google Inc. (Apple)` | pass · `Google Inc. (Apple)` | pass · `Google Inc. (Apple)` |
| ✅ | WebGL Renderer | pass · `ANGLE (Apple, ANGLE Metal Renderer: Apple M4, Unspecified Version)` | pass · `ANGLE (Apple, ANGLE Metal Renderer: Apple M4, Unspecified Version)` | pass · `ANGLE (Apple, ANGLE Metal Renderer: Apple M4, Unspecified Version)` |
| ⚠️ | Broken Image Dimensions | info · `` | pass · `16x16` | pass · `16x16` |
| ✅ | PHANTOM_UA | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | PHANTOM_PROPERTIES | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | PHANTOM_ETSL | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | PHANTOM_LANGUAGE | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | PHANTOM_WEBSOCKET | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | MQ_SCREEN | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | PHANTOM_OVERFLOW | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | PHANTOM_WINDOW_HEIGHT | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | HEADCHR_UA | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | HEADCHR_CHROME_OBJ | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | HEADCHR_PERMISSIONS | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | HEADCHR_PLUGINS | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | HEADCHR_IFRAME | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | CHR_DEBUG_TOOLS | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | SELENIUM_DRIVER | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | CHR_BATTERY | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | CHR_MEMORY | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | TRANSPARENT_PIXEL | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | SEQUENTUM | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | VIDEO_CODECS | pass · `ok` | pass · `ok` | pass · `ok` |
| ✅ | navigator.cookieEnabled | info · `document.write(navigator.cookieEnabled);
            true` | info · `document.write(navigator.cookieEnabled);
            true` | info · `document.write(navigator.cookieEnabled);
            true` |
| ✅ | navigator.doNotTrack | info · `document.write(navigator.doNotTrack);
            null` | info · `document.write(navigator.doNotTrack);
            null` | info · `document.write(navigator.doNotTrack);
            null` |
| ✅ | navigator.msDoNotTrack | info · `document.write(navigator.msDoNotTrack);
            undefined` | info · `document.write(navigator.msDoNotTrack);
            undefined` | info · `document.write(navigator.msDoNotTrack);
            undefined` |
| ✅ | navigator.sendBeacon | info · `document.write(navigator.sendBeacon());
            undefined` | info · `document.write(navigator.sendBeacon());` | info · `document.write(navigator.sendBeacon());` |
| ✅ | navigator.userAgent | info · `document.write(navigator.userAgent);
            Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/5…` | info · `document.write(navigator.userAgent);
            Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/5…` | info · `document.write(navigator.userAgent);
            Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/5…` |
| ✅ | navigator.appName | info · `document.write(navigator.appName);
            Netscape` | info · `document.write(navigator.appName);
            Netscape` | info · `document.write(navigator.appName);
            Netscape` |
| ✅ | navigator.vendor | info · `document.write(navigator.vendor);
            Google Inc.` | info · `document.write(navigator.vendor);
            Google Inc.` | info · `document.write(navigator.vendor);
            Google Inc.` |
| ✅ | navigator.appCodeName | info · `document.write(navigator.appCodeName);
            Mozilla` | info · `document.write(navigator.appCodeName);
            Mozilla` | info · `document.write(navigator.appCodeName);
            Mozilla` |
| ✅ | navigator.getUserMedia | info · `document.write(navigator.getUserMedia());` | info · `document.write(navigator.getUserMedia());` | info · `document.write(navigator.getUserMedia());` |
| ✅ | navigator.sayswho | info · `document.write(navigator.sayswho);
            undefined` | info · `document.write(navigator.sayswho);
            undefined` | info · `document.write(navigator.sayswho);
            undefined` |
| ✅ | navigator.javaEnabled | info · `document.write(navigator.javaEnabled());
            false` | info · `document.write(navigator.javaEnabled());
            false` | info · `document.write(navigator.javaEnabled());
            false` |
| ✅ | navigator.plugins | info · `document.write(JSON.stringify(navigator.plugins));
            {"0":{"0":{},"1":{}},"1":{"0":{},"1":{}},"2":{"…` | info · `document.write(JSON.stringify(navigator.plugins));
            {"0":{"0":{},"1":{}},"1":{"0":{},"1":{}},"2":{"…` | info · `document.write(JSON.stringify(navigator.plugins));
            {"0":{"0":{},"1":{}},"1":{"0":{},"1":{}},"2":{"…` |
| ✅ | screen.width | info · `document.write(screen.width);
            1920` | info · `document.write(screen.width);
            800` | info · `document.write(screen.width);
            1512` |
| ✅ | screen.height | info · `document.write(screen.height);
            1080` | info · `document.write(screen.height);
            600` | info · `document.write(screen.height);
            982` |
| ✅ | screen.colorDepth | info · `document.write(screen.colorDepth);
            24` | info · `document.write(screen.colorDepth);
            24` | info · `document.write(screen.colorDepth);
            30` |
| ✅ | navigator.language | info · `document.write(navigator.language);
            en-US` | info · `document.write(navigator.language);
            en-US` | info · `document.write(navigator.language);
            en-US` |
| ✅ | navigator.loadPurpose | info · `document.write(navigator.loadPurpose);
            undefined` | info · `document.write(navigator.loadPurpose);
            undefined` | info · `document.write(navigator.loadPurpose);
            undefined` |
| ✅ | navigator.platform | info · `document.write(navigator.platform);
            MacIntel` | info · `document.write(navigator.platform);
            MacIntel` | info · `document.write(navigator.platform);
            MacIntel` |
| ✅ | navigator.mediaDevices | info · `audioinput:  id = videoinput:  id = audiooutput:  id =` | info · `audioinput:  id = videoinput:  id = audiooutput:  id =` | info · `audioinput:  id = videoinput:  id = audiooutput:  id =` |
| ✅ | navigator.getBattery details | info · `Charging: trueLevel: 1` | info · `Charging: trueLevel: 1` | info · `Charging: trueLevel: 1` |
| ✅ | Canvas1 | info · `Hash: 2068257366` | info · `Hash: -1941328102` | info · `Hash: -1941328102` |
| ✅ | Canvas2 | info · `Hash: 2068257366` | info · `Hash: -1941328102` | info · `Hash: -1941328102` |
| ✅ | Canvas3 (iframe sandbox) | info · `Hash: 2068257366` | info · `Hash: -1941328102` | info · `Hash: -1941328102` |
| ✅ | Canvas4 (iframe sandbox) | info · `Hash: 2068257366` | info · `Hash: -1941328102` | info · `Hash: -1941328102` |
| ✅ | Canvas5 (iframe) | info · `Hash: 2068257366` | info · `Hash: -1941328102` | info · `Hash: -1941328102` |

## 4. CreepJS

| | field | candidate | reference | control |
|---|---|---|---|---|
| ✅ | `computed` | `true` | `true` | `true` |
| ➖ | `fpId` | `78513fd6b4ab5627236ae4624ebf89b567b332dd787c038d8d2067b3b0753d76` | `ff18ddb3f8156035d5b0ef6cba9da7c986a8df34b185a4ec4a180fc837d95c99` | `42cdd71e427599d855517230e52e307791f27b5114b329613791ce4f1adfdc30` |
| ➖ | `fuzzy` | `eff17c969b22118fb849edf142581216ffa513d38f657fff182a000000000000` | `faafe8bbb42e1639cc49405f42ee13e6ff969f6300d536ff1e1a000000000000` | `faafe816bf2e16a4bc49405f42e313e6ff0344c300d536ff132a000000000000` |
| ✅ | `likeHeadless` | `31%` | `31%` | `25%` |
| ✅ | `headlessPct` | `0%` | `0%` | `0%` |
| ✅ | `stealthPct` | `0%` | `0%` | `0%` |
| ➖ | `textLength` | `4136` | `4689` | `4747` |

