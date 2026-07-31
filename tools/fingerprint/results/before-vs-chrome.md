# Fingerprint comparison

| | candidate | reference |
|---|---|---|
| engine | `lightpanda` | `chrome-headed` |
| build | `1.0.0-dev.2+9a5018a7` | `Chrome/150.0.7871.187` |

## 1. JS fingerprint surface

33/90 probe keys identical to the reference.

| | key | candidate | reference (real Chrome) |
|---|---|---|---|
| ❌ | `navigator.userAgent` | `Lightpanda/1.0` | `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari…` |
| ✅ | `navigator.appCodeName` | `Mozilla` | `Mozilla` |
| ✅ | `navigator.appName` | `Netscape` | `Netscape` |
| ❌ | `navigator.appVersion` | `1.0` | `5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36` |
| ✅ | `navigator.platform` | `MacIntel` | `MacIntel` |
| ✅ | `navigator.product` | `Gecko` | `Gecko` |
| ❌ | `navigator.productSub` | ⚠️ `undefined` | `20030107` |
| ❌ | `navigator.vendor` | `` | `Google Inc.` |
| ❌ | `navigator.vendorSub` | ⚠️ `undefined` | `` |
| ✅ | `navigator.oscpu` | ⚠️ `undefined` | ⚠️ `undefined` |
| ✅ | `navigator.language` | `en-US` | `en-US` |
| ✅ | `navigator.languages` | `["en-US","en"]` | `["en-US","en"]` |
| ❌ | `navigator.hardwareConcurrency` | `4` | `10` |
| ❌ | `navigator.deviceMemory` | `8` | `16` |
| ✅ | `navigator.maxTouchPoints` | `0` | `0` |
| ✅ | `navigator.webdriver` | `false` | `false` |
| ❌ | `navigator.pdfViewerEnabled` | ⚠️ `undefined` | `true` |
| ✅ | `navigator.cookieEnabled` | `true` | `true` |
| ✅ | `navigator.doNotTrack` | `null` | `null` |
| ✅ | `navigator.onLine` | `true` | `true` |
| ❌ | `navigator.ownPropertyNames` | `["appCodeName","appName","appVersion","constructor","cookieEnabled","deviceMemory","doNotTrack","globalPrivacy…` | `["adAuctionComponents","appCodeName","appName","appVersion","bluetooth","canLoadAdAuctionFencedFrame","canShar…` |
| ❌ | `navigator.plugins.length` | `0` | `5` |
| ❌ | `navigator.plugins.names` | `[]` | `["PDF Viewer","Chrome PDF Viewer","Chromium PDF Viewer","Microsoft Edge PDF Viewer","WebKit built-in PDF"]` |
| ❌ | `navigator.mimeTypes.length` | ❌ throws: Cannot read properties of undefined (reading 'length') | `2` |
| ❌ | `navigator.userAgentData.brands` | `[{"brand":"Lightpanda","version":"1"}]` | `[{"brand":"Not;A=Brand","version":"8"},{"brand":"Chromium","version":"150"},{"brand":"Google Chrome","version"…` |
| ✅ | `navigator.userAgentData.mobile` | `false` | `false` |
| ✅ | `navigator.userAgentData.platform` | `macOS` | `macOS` |
| ❌ | `navigator.userAgentData.highEntropy` | `{"brands":[{"brand":"Lightpanda","version":"1"}],"mobile":false,"platform":"macOS","architecture":"arm","bitne…` | `{"architecture":"arm","bitness":"64","brands":[{"brand":"Not;A=Brand","version":"8"},{"brand":"Chromium","vers…` |
| ✅ | `navigator.permissions.notifications` | `prompt` | `prompt` |
| ❌ | `navigator.connection` | ❌ throws: Cannot read properties of undefined (reading 'effectiveType') | `{"effectiveType":"4g","rtt":100,"downlink":1.45,"saveData":false}` |
| ❌ | `navigator.mediaDevices` | ❌ throws: Cannot read properties of undefined (reading 'enumerateDevices') | `function` |
| ❌ | `navigator.getBattery` | `undefined` | `function` |
| ✅ | `navigator.storage.estimate` | `number` | `number` |
| ❌ | `window.chrome` | `undefined` | `object` |
| ❌ | `window.chrome.keys` | `null` | `["app","csi","loadTimes"]` |
| ❌ | `window.chrome.runtime` | ❌ throws: Cannot read properties of undefined (reading 'runtime') | `undefined` |
| ❌ | `window.chrome.csi` | ❌ throws: Cannot read properties of undefined (reading 'csi') | `function` |
| ❌ | `window.chrome.loadTimes` | ❌ throws: Cannot read properties of undefined (reading 'loadTimes') | `function` |
| ❌ | `window.chrome.app.isInstalled` | ❌ throws: Cannot read properties of undefined (reading 'app') | `false` |
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
| ❌ | `canvas.toDataURL.type` | `undefined` | `function` |
| ❌ | `canvas.toDataURL.fingerprint` | ❌ throws: c.toDataURL is not a function | `{"len":7614,"prefix":"data:image/png;base64,iVBORw0K","hash":725900497}` |
| ❌ | `canvas.getImageData.nonzero` | `{"first4":[0,0,0,0],"anyNonZero":false}` | `{"first4":[255,0,0,255],"anyNonZero":true}` |
| ❌ | `canvas.measureText` | ❌ throws: document.createElement(...).getContext(...).measureText is not a function | `89.9658203125` |
| ❌ | `webgl.getContext.webgl` | `null` | `ok` |
| ❌ | `webgl.getContext.webgl2` | `null` | `ok` |
| ❌ | `webgl.getContext.experimental-webgl` | `null` | `ok` |
| ❌ | `webgl.params` | `null` | `{"VENDOR":"WebKit","RENDERER":"WebKit WebGL","VERSION":"WebGL 1.0 (OpenGL ES 2.0 Chromium)","SHADING_LANGUAGE_…` |
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
| ❌ | `window.ownPropertyNames.count` | `460` | `1233` |

## 2. HTTP request headers (local origin)

| path | candidate header order | reference header order |
|---|---|---|
| `/` | Host, Accept-Encoding, User-Agent, Sec-Ch-Ua, Accept-Language, Accept | Host, Connection, sec-ch-ua, sec-ch-ua-mobile, sec-ch-ua-platform, Upgrade-Insecure-Requests, User-Agent, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-User, Sec-Fetch-Dest, Accept-Encoding, Accept-Language |
| `/api/fetch` | Host, Accept, Accept-Encoding, User-Agent, Sec-Ch-Ua, Accept-Language, Referer | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/api/xhr` | Host, Accept, Accept-Encoding, User-Agent, Sec-Ch-Ua, Accept-Language, Referer | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/asset.css` | **never requested** | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/asset.js` | Host, Accept, Accept-Encoding, User-Agent, Sec-Ch-Ua, Accept-Language, Referer | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/asset.png` | **never requested** | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/favicon.ico` | **never requested** | Host, Connection, sec-ch-ua-platform, User-Agent, sec-ch-ua, sec-ch-ua-mobile, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/frame.html` | Host, Accept-Encoding, User-Agent, Sec-Ch-Ua, Accept-Language, Accept, Referer | Host, Connection, sec-ch-ua, sec-ch-ua-mobile, sec-ch-ua-platform, Upgrade-Insecure-Requests, User-Agent, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest, Referer, Accept-Encoding, Accept-Language |
| `/nav` | Host, Accept-Encoding, User-Agent, Sec-Ch-Ua, Accept-Language, Accept | Host, Connection, sec-ch-ua, sec-ch-ua-mobile, sec-ch-ua-platform, Upgrade-Insecure-Requests, User-Agent, Accept, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-User, Sec-Fetch-Dest, Accept-Encoding, Accept-Language |

### Header values on the document request

| | header | candidate | reference |
|---|---|---|---|
| ❌ | `host` | `127.0.0.1:56860` | `127.0.0.1:57230` |
| ❌ | `connection` | *(absent)* | `keep-alive` |
| ❌ | `sec-ch-ua` | `"Lightpanda";v="1"` | `"Not;A=Brand";v="8", "Chromium";v="150", "Google Chrome";v="150"` |
| ❌ | `sec-ch-ua-mobile` | *(absent)* | `?0` |
| ❌ | `sec-ch-ua-platform` | *(absent)* | `"macOS"` |
| ❌ | `upgrade-insecure-requests` | *(absent)* | `1` |
| ❌ | `user-agent` | `Lightpanda/1.0` | `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari…` |
| ❌ | `accept` | `text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8` | `text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/s…` |
| ❌ | `sec-fetch-site` | *(absent)* | `none` |
| ❌ | `sec-fetch-mode` | *(absent)* | `navigate` |
| ❌ | `sec-fetch-user` | *(absent)* | `?1` |
| ❌ | `sec-fetch-dest` | *(absent)* | `document` |
| ❌ | `accept-encoding` | `deflate, gzip, br` | `gzip, deflate, br, zstd` |
| ✅ | `accept-language` | `en-US,en;q=0.9` | `en-US,en;q=0.9` |

## 3. bot.sannysoft.com

Candidate FAIL rows: **11** — `Chrome (New)`, `Plugins Length (Old)`, `Plugins is of type PluginArray`, `WebGL Vendor`, `WebGL Renderer`, `CHR_MEMORY`, `Canvas1`, `Canvas2`, `Canvas3 (iframe sandbox)`, `Canvas4 (iframe sandbox)`, `Canvas5 (iframe)`

| | test | candidate | reference |
|---|---|---|---|
| ✅ | User Agent (Old) | pass · `Lightpanda/1.0` | pass · `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari…` |
| ✅ | WebDriver (New) | pass · `missing (passed)` | pass · `missing (passed)` |
| ✅ | WebDriver Advanced | pass · `passed` | pass · `passed` |
| ❌ | Chrome (New) | FAIL · `missing (failed)` | pass · `present (passed)` |
| ✅ | Permissions (New) | pass · `prompt` | pass · `prompt` |
| ❌ | Plugins Length (Old) | FAIL · `0` | pass · `5` |
| ❌ | Plugins is of type PluginArray | FAIL · `failed` | pass · `passed` |
| ✅ | Languages (Old) | pass · `en-US,en` | pass · `en-US,en` |
| ❌ | WebGL Vendor | FAIL · `Canvas has no webgl context` | pass · `Google Inc. (Apple)` |
| ❌ | WebGL Renderer | FAIL · `Canvas has no webgl context` | pass · `ANGLE (Apple, ANGLE Metal Renderer: Apple M4, Unspecified Version)` |
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
| ❌ | CHR_MEMORY | FAIL · `FAIL` | pass · `ok` |
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
            Lightpanda/1.0` | info · `document.write(navigator.userAgent);
            Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/5…` |
| ✅ | navigator.appName | info · `document.write(navigator.appName);
            Netscape` | info · `document.write(navigator.appName);
            Netscape` |
| ✅ | navigator.vendor | info · `document.write(navigator.vendor);` | info · `document.write(navigator.vendor);
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
            {}` | info · `document.write(JSON.stringify(navigator.plugins));
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
| ✅ | navigator.mediaDevices | info · `const med = document.getElementById('media1');
              ( async () => {
                let devices = awa…` | info · `audioinput:  id = videoinput:  id = audiooutput:  id =` |
| ✅ | navigator.getBattery details | info · `const battery1 = document.getElementById('battery1');
              ( async () => {
                const b = …` | info · `Charging: trueLevel: 0.94` |
| ❌ | Canvas1 | FAIL · `Canvas failed` | info · `Hash: -1941328102` |
| ❌ | Canvas2 | FAIL · `Canvas failed` | info · `Hash: -1941328102` |
| ❌ | Canvas3 (iframe sandbox) | FAIL · `Canvas failed` | info · `Hash: -1941328102` |
| ❌ | Canvas4 (iframe sandbox) | FAIL · `Canvas failed` | info · `Hash: -1941328102` |
| ❌ | Canvas5 (iframe) | FAIL · `Canvas failed` | info · `Hash: -1941328102` |

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

