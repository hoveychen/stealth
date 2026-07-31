# Fingerprint comparison

| | candidate | reference |
|---|---|---|
| engine | `lightpanda` | `chrome-headed` |
| build | `1.0.0-dev.36+7d413f03a` | `Chrome/150.0.7871.187` |

## 1. JS fingerprint surface

59/90 probe keys identical to the reference.

| | key | candidate | reference (real Chrome) |
|---|---|---|---|
| ✅ | `navigator.userAgent` | `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari…` | `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari…` |
| ✅ | `navigator.appCodeName` | `Mozilla` | `Mozilla` |
| ✅ | `navigator.appName` | `Netscape` | `Netscape` |
| ✅ | `navigator.appVersion` | `5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36` | `5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36` |
| ✅ | `navigator.platform` | `MacIntel` | `MacIntel` |
| ✅ | `navigator.product` | `Gecko` | `Gecko` |
| ✅ | `navigator.productSub` | `20030107` | `20030107` |
| ✅ | `navigator.vendor` | `Google Inc.` | `Google Inc.` |
| ✅ | `navigator.vendorSub` | `` | `` |
| ✅ | `navigator.oscpu` | ⚠️ `undefined` | ⚠️ `undefined` |
| ✅ | `navigator.language` | `en-US` | `en-US` |
| ✅ | `navigator.languages` | `["en-US","en"]` | `["en-US","en"]` |
| ❌ | `navigator.hardwareConcurrency` | `8` | `10` |
| ❌ | `navigator.deviceMemory` | `8` | `16` |
| ✅ | `navigator.maxTouchPoints` | `0` | `0` |
| ✅ | `navigator.webdriver` | `false` | `false` |
| ✅ | `navigator.pdfViewerEnabled` | `true` | `true` |
| ✅ | `navigator.cookieEnabled` | `true` | `true` |
| ✅ | `navigator.doNotTrack` | `null` | `null` |
| ✅ | `navigator.onLine` | `true` | `true` |
| ❌ | `navigator.ownPropertyNames` | `["appCodeName","appName","appVersion","connection","constructor","cookieEnabled","deviceMemory","doNotTrack","…` | `["adAuctionComponents","appCodeName","appName","appVersion","bluetooth","canLoadAdAuctionFencedFrame","canShar…` |
| ✅ | `navigator.plugins.length` | `5` | `5` |
| ✅ | `navigator.plugins.names` | `["PDF Viewer","Chrome PDF Viewer","Chromium PDF Viewer","Microsoft Edge PDF Viewer","WebKit built-in PDF"]` | `["PDF Viewer","Chrome PDF Viewer","Chromium PDF Viewer","Microsoft Edge PDF Viewer","WebKit built-in PDF"]` |
| ✅ | `navigator.mimeTypes.length` | `2` | `2` |
| ✅ | `navigator.userAgentData.brands` | `[{"brand":"Not;A=Brand","version":"8"},{"brand":"Chromium","version":"150"},{"brand":"Google Chrome","version"…` | `[{"brand":"Not;A=Brand","version":"8"},{"brand":"Chromium","version":"150"},{"brand":"Google Chrome","version"…` |
| ✅ | `navigator.userAgentData.mobile` | `false` | `false` |
| ✅ | `navigator.userAgentData.platform` | `macOS` | `macOS` |
| ❌ | `navigator.userAgentData.highEntropy` | `{"brands":[{"brand":"Not;A=Brand","version":"8"},{"brand":"Chromium","version":"150"},{"brand":"Google Chrome"…` | `{"architecture":"arm","bitness":"64","brands":[{"brand":"Not;A=Brand","version":"8"},{"brand":"Chromium","vers…` |
| ✅ | `navigator.permissions.notifications` | `prompt` | `prompt` |
| ✅ | `navigator.connection` | `{"effectiveType":"4g","rtt":100,"downlink":1.45,"saveData":false}` | `{"effectiveType":"4g","rtt":100,"downlink":1.45,"saveData":false}` |
| ✅ | `navigator.mediaDevices` | `function` | `function` |
| ✅ | `navigator.getBattery` | `function` | `function` |
| ✅ | `navigator.storage.estimate` | `number` | `number` |
| ✅ | `window.chrome` | `object` | `object` |
| ✅ | `window.chrome.keys` | `["app","csi","loadTimes"]` | `["app","csi","loadTimes"]` |
| ✅ | `window.chrome.runtime` | `undefined` | `undefined` |
| ✅ | `window.chrome.csi` | `function` | `function` |
| ✅ | `window.chrome.loadTimes` | `function` | `function` |
| ✅ | `window.chrome.app.isInstalled` | `false` | `false` |
| ✅ | `tell.cdc_props` | `[]` | `[]` |
| ✅ | `tell.documentElement.webdriver` | `null` | `null` |
| ✅ | `tell.eval.toString.length` | `33` | `33` |
| ✅ | `tell.Function.toString.native` | `function toString() { [native code] }` | `function toString() { [native code] }` |
| ✅ | `tell.navigator.toStringTag` | `[object Navigator]` | `[object Navigator]` |
| ✅ | `tell.error.stack.shape` | `TypeError: Cannot read properties of null (reading 'f') \|     at <anonymous>:74:18 \|     at get (<anonymous>:1…` | `TypeError: Cannot read properties of null (reading 'f') \|     at <anonymous>:74:18 \|     at get (<anonymous>:1…` |
| ✅ | `tell.Notification.permission` | `default` | `default` |
| ✅ | `tell.outerdim.zero` | `false` | `false` |
| ❌ | `screen.width` | `1920` | `1512` |
| ❌ | `screen.height` | `1080` | `982` |
| ❌ | `screen.availWidth` | `1920` | `1512` |
| ❌ | `screen.availHeight` | `1040` | `949` |
| ❌ | `screen.availLeft` | ⚠️ `undefined` | `0` |
| ❌ | `screen.availTop` | ⚠️ `undefined` | `33` |
| ❌ | `screen.colorDepth` | `24` | `30` |
| ❌ | `screen.pixelDepth` | `24` | `30` |
| ✅ | `screen.orientation` | `{"type":"landscape-primary","angle":0}` | `{"type":"landscape-primary","angle":0}` |
| ❌ | `window.innerWidth` | `1920` | `1200` |
| ❌ | `window.innerHeight` | `1080` | `818` |
| ❌ | `window.outerWidth` | ⚠️ `undefined` | `1200` |
| ❌ | `window.outerHeight` | ⚠️ `undefined` | `905` |
| ❌ | `window.devicePixelRatio` | `1` | `2` |
| ❌ | `window.screenX` | ⚠️ `undefined` | `22` |
| ❌ | `window.screenY` | ⚠️ `undefined` | `55` |
| ❌ | `window.toolbar.visible` | ❌ throws: Cannot read properties of undefined (reading 'visible') | `true` |
| ✅ | `intl.timeZone` | `Asia/Shanghai` | `Asia/Shanghai` |
| ✅ | `intl.locale` | `en-US` | `en-US` |
| ✅ | `date.timezoneOffset` | `-480` | `-480` |
| ✅ | `date.toString` | `Thu Jan 01 1970 08:00:00 GMT+0800 (China Standard Time)` | `Thu Jan 01 1970 08:00:00 GMT+0800 (China Standard Time)` |
| ✅ | `canvas.getContext2d` | `object` | `object` |
| ✅ | `canvas.toDataURL.type` | `function` | `function` |
| ❌ | `canvas.toDataURL.fingerprint` | `{"len":370,"prefix":"data:image/png;base64,iVBORw0K","hash":-546904589}` | `{"len":7614,"prefix":"data:image/png;base64,iVBORw0K","hash":725900497}` |
| ✅ | `canvas.getImageData.nonzero` | `{"first4":[255,0,0,255],"anyNonZero":true}` | `{"first4":[255,0,0,255],"anyNonZero":true}` |
| ✅ | `canvas.measureText` | `89.9658203125` | `89.9658203125` |
| ✅ | `webgl.getContext.webgl` | `ok` | `ok` |
| ✅ | `webgl.getContext.webgl2` | `ok` | `ok` |
| ✅ | `webgl.getContext.experimental-webgl` | `ok` | `ok` |
| ✅ | `webgl.params` | `{"VENDOR":"WebKit","RENDERER":"WebKit WebGL","VERSION":"WebGL 1.0 (OpenGL ES 2.0 Chromium)","SHADING_LANGUAGE_…` | `{"VENDOR":"WebKit","RENDERER":"WebKit WebGL","VERSION":"WebGL 1.0 (OpenGL ES 2.0 Chromium)","SHADING_LANGUAGE_…` |
| ❌ | `audio.AudioContext` | `undefined` | `function` |
| ❌ | `audio.sampleRate` | ❌ throws: (window.AudioContext || window.webkitAudioContext) is not a constructor | `48000` |
| ❌ | `audio.OfflineAudioContext` | `undefined` | `function` |
| ✅ | `fonts.api` | `function` | `function` |
| ❌ | `fonts.widths` | `{"monospace":5,"sans-serif":5,"serif":5,"Arial":5,"Helvetica Neue":5,"Times New Roman":5}` | `{"monospace":620,"sans-serif":620,"serif":620,"Arial":648,"Helvetica Neue":662,"Times New Roman":620}` |
| ❌ | `media.canPlayType` | `{"h264":"probably","webm":"probably","ogg":"probably"}` | `{"h264":"probably","webm":"probably","ogg":""}` |
| ❌ | `rtc.RTCPeerConnection` | `undefined` | `function` |
| ❌ | `perf.memory` | `null` | `[]` |
| ❌ | `speech.voices.length` | ❌ throws: Cannot read properties of undefined (reading 'getVoices') | `0` |
| ✅ | `matchMedia.dark` | `false` | `false` |
| ✅ | `matchMedia.coarsePointer` | `false` | `false` |
| ❌ | `matchMedia.hover` | `false` | `true` |
| ❌ | `window.ownPropertyNames.count` | `486` | `1233` |

## 2. HTTP request headers (local origin)

| path | candidate header order | reference header order |
|---|---|---|
| `/` | Host, Accept-Encoding, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Sec-Ch-Ua-Platform, User-Agent, Accept-Language, Accept, Sec-Fetch-Dest, Sec-Fetch-Mode, Sec-Fetch-Site, Upgrade-Insecure-Requests, Sec-Fetch-User | Host, Connection, sec-ch-ua, sec-ch-ua-mobile, sec-ch-ua-platform, Upgrade-Insecure-Requests, User-Agent, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-User, Sec-Fetch-Dest, Accept-Encoding, Accept-Language |
| `/api/fetch` | Host, Accept-Encoding, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Sec-Ch-Ua-Platform, User-Agent, Accept-Language, Referer, Accept, Sec-Fetch-Dest, Sec-Fetch-Mode, Sec-Fetch-Site | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/api/xhr` | Host, Accept-Encoding, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Sec-Ch-Ua-Platform, User-Agent, Accept-Language, Referer, Accept, Sec-Fetch-Dest, Sec-Fetch-Mode, Sec-Fetch-Site | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/asset.css` | Host, Accept-Encoding, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Sec-Ch-Ua-Platform, User-Agent, Accept-Language, Referer, Accept, Sec-Fetch-Dest, Sec-Fetch-Mode, Sec-Fetch-Site | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/asset.js` | Host, Accept-Encoding, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Sec-Ch-Ua-Platform, User-Agent, Accept-Language, Referer, Accept, Sec-Fetch-Dest, Sec-Fetch-Mode, Sec-Fetch-Site | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/asset.png` | Host, Accept-Encoding, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Sec-Ch-Ua-Platform, User-Agent, Accept-Language, Referer, Accept, Sec-Fetch-Dest, Sec-Fetch-Mode, Sec-Fetch-Site | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/favicon.ico` | Host, Accept-Encoding, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Sec-Ch-Ua-Platform, User-Agent, Accept-Language, Referer, Accept, Sec-Fetch-Dest, Sec-Fetch-Mode, Sec-Fetch-Site | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/frame.html` | Host, Accept-Encoding, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Sec-Ch-Ua-Platform, User-Agent, Accept-Language, Accept, Sec-Fetch-Dest, Sec-Fetch-Mode, Sec-Fetch-Site, Upgrade-Insecure-Requests, Referer | Host, Connection, sec-ch-ua, sec-ch-ua-mobile, sec-ch-ua-platform, Upgrade-Insecure-Requests, User-Agent, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/nav` | Host, Accept-Encoding, Sec-Ch-Ua, Sec-Ch-Ua-Mobile, Sec-Ch-Ua-Platform, User-Agent, Accept-Language, Accept, Sec-Fetch-Dest, Sec-Fetch-Mode, Sec-Fetch-Site, Upgrade-Insecure-Requests, Sec-Fetch-User | Host, Connection, sec-ch-ua, sec-ch-ua-mobile, sec-ch-ua-platform, Upgrade-Insecure-Requests, User-Agent, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-User, Sec-Fetch-Dest, Accept-Encoding, Accept-Language |

### Header values on the document request

| | header | candidate | reference |
|---|---|---|---|
| ❌ | `host` | `127.0.0.1:58686` | `127.0.0.1:57230` |
| ❌ | `connection` | *(absent)* | `keep-alive` |
| ✅ | `sec-ch-ua` | `"Not;A=Brand";v="8", "Chromium";v="150", "Google Chrome";v="150"` | `"Not;A=Brand";v="8", "Chromium";v="150", "Google Chrome";v="150"` |
| ✅ | `sec-ch-ua-mobile` | `?0` | `?0` |
| ✅ | `sec-ch-ua-platform` | `"macOS"` | `"macOS"` |
| ✅ | `upgrade-insecure-requests` | `1` | `1` |
| ✅ | `user-agent` | `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari…` | `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari…` |
| ✅ | `accept` | `text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/s…` | `text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/s…` |
| ✅ | `sec-fetch-site` | `none` | `none` |
| ✅ | `sec-fetch-mode` | `navigate` | `navigate` |
| ✅ | `sec-fetch-user` | `?1` | `?1` |
| ✅ | `sec-fetch-dest` | `document` | `document` |
| ❌ | `accept-encoding` | `gzip, deflate, br` | `gzip, deflate, br, zstd` |
| ✅ | `accept-language` | `en-US,en;q=0.9` | `en-US,en;q=0.9` |

## 3. bot.sannysoft.com

Candidate FAIL rows: **0** — none

| | test | candidate | reference |
|---|---|---|---|
| ✅ | User Agent (Old) | pass · `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari…` | pass · `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari…` |
| ✅ | WebDriver (New) | pass · `missing (passed)` | pass · `missing (passed)` |
| ✅ | WebDriver Advanced | pass · `passed` | pass · `passed` |
| ✅ | Chrome (New) | pass · `present (passed)` | pass · `present (passed)` |
| ✅ | Permissions (New) | pass · `prompt` | pass · `prompt` |
| ✅ | Plugins Length (Old) | pass · `5` | pass · `5` |
| ✅ | Plugins is of type PluginArray | pass · `passed` | pass · `passed` |
| ✅ | Languages (Old) | pass · `en-US,en` | pass · `en-US,en` |
| ✅ | WebGL Vendor | pass · `Google Inc. (Apple)` | pass · `Google Inc. (Apple)` |
| ✅ | WebGL Renderer | pass · `ANGLE (Apple, ANGLE Metal Renderer: Apple M4, Unspecified Version)` | pass · `ANGLE (Apple, ANGLE Metal Renderer: Apple M4, Unspecified Version)` |
| ⚠️ | Broken Image Dimensions | info · `` | pass · `16x16` |
| ✅ | PHANTOM_UA | pass · `ok` | pass · `ok` |
| ✅ | PHANTOM_PROPERTIES | pass · `ok` | pass · `ok` |
| ✅ | PHANTOM_ETSL | pass · `ok` | pass · `ok` |
| ✅ | PHANTOM_LANGUAGE | pass · `ok` | pass · `ok` |
| ✅ | PHANTOM_WEBSOCKET | pass · `ok` | pass · `ok` |
| ✅ | MQ_SCREEN | pass · `ok` | pass · `ok` |
| ✅ | PHANTOM_OVERFLOW | pass · `ok` | pass · `ok` |
| ✅ | PHANTOM_WINDOW_HEIGHT | pass · `ok` | pass · `ok` |
| ✅ | HEADCHR_UA | pass · `ok` | pass · `ok` |
| ✅ | HEADCHR_CHROME_OBJ | pass · `ok` | pass · `ok` |
| ✅ | HEADCHR_PERMISSIONS | pass · `ok` | pass · `ok` |
| ✅ | HEADCHR_PLUGINS | pass · `ok` | pass · `ok` |
| ✅ | HEADCHR_IFRAME | pass · `ok` | pass · `ok` |
| ✅ | CHR_DEBUG_TOOLS | pass · `ok` | pass · `ok` |
| ✅ | SELENIUM_DRIVER | pass · `ok` | pass · `ok` |
| ✅ | CHR_BATTERY | pass · `ok` | pass · `ok` |
| ✅ | CHR_MEMORY | pass · `ok` | pass · `ok` |
| ✅ | TRANSPARENT_PIXEL | pass · `ok` | pass · `ok` |
| ✅ | SEQUENTUM | pass · `ok` | pass · `ok` |
| ✅ | VIDEO_CODECS | pass · `ok` | pass · `ok` |
| ✅ | navigator.cookieEnabled | info · `document.write(navigator.cookieEnabled);
            true` | info · `document.write(navigator.cookieEnabled);
            true` |
| ✅ | navigator.doNotTrack | info · `document.write(navigator.doNotTrack);
            null` | info · `document.write(navigator.doNotTrack);
            null` |
| ✅ | navigator.msDoNotTrack | info · `document.write(navigator.msDoNotTrack);
            undefined` | info · `document.write(navigator.msDoNotTrack);
            undefined` |
| ✅ | navigator.sendBeacon | info · `document.write(navigator.sendBeacon());
            undefined` | info · `document.write(navigator.sendBeacon());` |
| ✅ | navigator.userAgent | info · `document.write(navigator.userAgent);
            Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/5…` | info · `document.write(navigator.userAgent);
            Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/5…` |
| ✅ | navigator.appName | info · `document.write(navigator.appName);
            Netscape` | info · `document.write(navigator.appName);
            Netscape` |
| ✅ | navigator.vendor | info · `document.write(navigator.vendor);
            Google Inc.` | info · `document.write(navigator.vendor);
            Google Inc.` |
| ✅ | navigator.appCodeName | info · `document.write(navigator.appCodeName);
            Mozilla` | info · `document.write(navigator.appCodeName);
            Mozilla` |
| ✅ | navigator.getUserMedia | info · `document.write(navigator.getUserMedia());` | info · `document.write(navigator.getUserMedia());` |
| ✅ | navigator.sayswho | info · `document.write(navigator.sayswho);
            undefined` | info · `document.write(navigator.sayswho);
            undefined` |
| ✅ | navigator.javaEnabled | info · `document.write(navigator.javaEnabled());
            false` | info · `document.write(navigator.javaEnabled());
            false` |
| ✅ | navigator.plugins | info · `document.write(JSON.stringify(navigator.plugins));
            {"0":{"0":{},"1":{}},"1":{"0":{},"1":{}},"2":{"…` | info · `document.write(JSON.stringify(navigator.plugins));
            {"0":{"0":{},"1":{}},"1":{"0":{},"1":{}},"2":{"…` |
| ✅ | screen.width | info · `document.write(screen.width);
            1920` | info · `document.write(screen.width);
            1512` |
| ✅ | screen.height | info · `document.write(screen.height);
            1080` | info · `document.write(screen.height);
            982` |
| ✅ | screen.colorDepth | info · `document.write(screen.colorDepth);
            24` | info · `document.write(screen.colorDepth);
            30` |
| ✅ | navigator.language | info · `document.write(navigator.language);
            en-US` | info · `document.write(navigator.language);
            en-US` |
| ✅ | navigator.loadPurpose | info · `document.write(navigator.loadPurpose);
            undefined` | info · `document.write(navigator.loadPurpose);
            undefined` |
| ✅ | navigator.platform | info · `document.write(navigator.platform);
            MacIntel` | info · `document.write(navigator.platform);
            MacIntel` |
| ✅ | navigator.mediaDevices | info · `audioinput:  id = videoinput:  id = audiooutput:  id =` | info · `audioinput:  id = videoinput:  id = audiooutput:  id =` |
| ✅ | navigator.getBattery details | info · `Charging: trueLevel: 1` | info · `Charging: trueLevel: 0.94` |
| ✅ | Canvas1 | info · `Hash: 2068257366` | info · `Hash: -1941328102` |
| ✅ | Canvas2 | info · `Hash: 2068257366` | info · `Hash: -1941328102` |
| ✅ | Canvas3 (iframe sandbox) | info · `Hash: 2068257366` | info · `Hash: -1941328102` |
| ✅ | Canvas4 (iframe sandbox) | info · `Hash: 2068257366` | info · `Hash: -1941328102` |
| ✅ | Canvas5 (iframe) | info · `Hash: 2068257366` | info · `Hash: -1941328102` |

## 4. CreepJS

| | field | candidate | reference |
|---|---|---|---|
| ❌ | `computed` | `false` | `true` |
| ❌ | `fpId` | `Computing...` | `c3e4fe997b993532473b2321f94f47e2bc452ab47c02b6e50fa388a0ff63688d` |
| ❌ | `fuzzy` | `0000000000000000000000000000000000000000000000000000000000000000` | `faafe816cd2d16a4c439495f42e613e6ff0344ccd0b536ff262a000000000000` |
| ❌ | `likeHeadless` | `0%` | `31%` |
| ✅ | `headlessPct` | `0%` | `0%` |
| ✅ | `stealthPct` | `0%` | `0%` |
| ❌ | `textLength` | `1347` | `4725` |

