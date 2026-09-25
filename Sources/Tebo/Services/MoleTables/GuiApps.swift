import Foundation

// MARK: - GUI Apps table
// Ported from tw93/Mole lib/clean/app_caches.sh (GPL-3.0): communication,
// design, media/video player and download-manager caches. Data only — no disk
// access. Video-editing tools (Final Cut / JianyingPro / DaVinci), gaming,
// AI assistants and the other GUI categories are separate waves.

private let wechatGuard = MoleProcessGuard(
    family: "WeChat",
    exactProcessNames: ["WeChat", "WeChatAppEx"]
)
private let wecomGuard = MoleProcessGuard(
    family: "WeCom",
    exactProcessNames: ["企业微信", "WeCom", "WXWork", "WeComAgent"]
)
private let feishuGuard = MoleProcessGuard(
    family: "Feishu/Lark",
    exactProcessNames: ["Feishu", "Lark"]
)
private let notionGuard = MoleProcessGuard.exact("Notion")
private let fcpGuard = MoleProcessGuard(
    family: "Final Cut Pro",
    exactProcessNames: ["Final Cut Pro"],
    pathSubstrings: ["/Final Cut Pro.app/"]
)
private let jianyingGuard = MoleProcessGuard(
    family: "JianyingPro",
    exactProcessNames: ["VideoFusion-macOS"],
    pathSubstrings: ["/VideoFusion-macOS.app/Contents/MacOS/VideoFusion-macOS"]
)
private let autodeskGuard = MoleProcessGuard(
    family: "Autodesk",
    exactProcessNames: [
        "AcCoreConsole", "ADPClientService", "streamer",
        "Fusion Client Downloader", "Fusion 360 Client Downloader",
    ],
    pathSubstrings: [
        "com.autodesk.", "/AcCoreConsole", "/ADPClientService", "/streamer",
        "Autodesk Fusion", "Fusion 360", "Fusion360",
    ]
)

public enum GuiApps {

    // Builds a row for this table: home-relative, safe by default.
    private static func target(
        _ label: String,
        _ path: String,
        kind: MoleTargetKind,
        explanation: String,
        processGuard: MoleProcessGuard? = nil,
        pruneRule: MolePruneRule? = nil,
        source: String
    ) -> CleanTarget {
        CleanTarget(
            label: label,
            group: .guiApps,
            path: .homeRelative(path),
            kind: kind,
            explanation: explanation,
            processGuard: processGuard,
            pruneRule: pruneRule,
            source: source
        )
    }

    // Rows under user-data folders (Movies) stay .review, never .safe.
    private static func reviewTarget(
        _ label: String,
        _ path: String,
        kind: MoleTargetKind,
        explanation: String,
        processGuard: MoleProcessGuard? = nil,
        pruneRule: MolePruneRule? = nil,
        source: String
    ) -> CleanTarget {
        CleanTarget(
            label: label,
            group: .guiApps,
            path: .homeRelative(path),
            kind: kind,
            risk: .review,
            explanation: explanation,
            processGuard: processGuard,
            pruneRule: pruneRule,
            source: source
        )
    }

    private static let wecomCef = "Library/Containers/com.tencent.WeWorkMac/Data/Documents/cefcache"

    public static let all: [CleanTarget] = [
        // -- Communication apps -----------------------------------------------------
        target(
            "Discord cache",
            "Library/Application Support/discord/Cache",
            kind: .directorySweep,
            explanation: "Electron renderer cache for Discord. Rebuilt on next launch; messages and login stay intact.",
            source: "mole lib/clean/app_caches.sh:847"
        ),
        target(
            "Legcord cache",
            "Library/Application Support/legcord/Cache",
            kind: .directorySweep,
            explanation: "Legcord (Discord client) Electron cache. Rebuilt on next launch.",
            source: "mole lib/clean/app_caches.sh:848"
        ),
        target(
            "Slack cache",
            "Library/Application Support/Slack/Cache",
            kind: .directorySweep,
            explanation: "Slack's Electron cache. Rebuilt on next launch; conversations live on Slack's servers.",
            source: "mole lib/clean/app_caches.sh:849"
        ),
        target(
            "Zoom cache",
            "Library/Caches/us.zoom.xos",
            kind: .directorySweep,
            explanation: "Zoom client cache. Rebuilt on demand.",
            source: "mole lib/clean/app_caches.sh:850"
        ),
        target(
            "WeChat cache",
            "Library/Caches/com.tencent.xinWeChat",
            kind: .directorySweep,
            explanation: "WeChat bundle-ID cache. Chat databases under Documents are never touched.",
            source: "mole lib/clean/app_caches.sh:851"
        ),
        target(
            "Telegram cache",
            "Library/Caches/ru.keepcoder.Telegram",
            kind: .directorySweep,
            explanation: "Telegram media/cache files. Re-downloaded from Telegram's servers on demand.",
            source: "mole lib/clean/app_caches.sh:852"
        ),
        target(
            "Microsoft Teams cache",
            "Library/Caches/com.microsoft.teams2",
            kind: .directorySweep,
            explanation: "New Teams (teams2) cache. Rebuilt on next launch.",
            source: "mole lib/clean/app_caches.sh:854"
        ),
        target(
            "WhatsApp cache",
            "Library/Caches/net.whatsapp.WhatsApp",
            kind: .directorySweep,
            explanation: "WhatsApp desktop cache. Chat history is backed by your phone and never touched.",
            source: "mole lib/clean/app_caches.sh:855"
        ),
        target(
            "Skype cache",
            "Library/Caches/com.skype.skype",
            kind: .directorySweep,
            explanation: "Skype client cache. Rebuilt on next launch.",
            source: "mole lib/clean/app_caches.sh:856"
        ),
        target(
            "Tencent Meeting cache",
            "Library/Caches/com.tencent.meeting",
            kind: .directorySweep,
            explanation: "Tencent Meeting cache. Rebuilt on demand.",
            source: "mole lib/clean/app_caches.sh:857"
        ),
        target(
            "WeCom cache",
            "Library/Caches/com.tencent.WeWorkMac",
            kind: .directorySweep,
            explanation: "WeCom bundle-ID cache. Message databases under Documents are never touched.",
            source: "mole lib/clean/app_caches.sh:858"
        ),
        target(
            "QQ cache",
            "Library/Caches/com.tencent.qq",
            kind: .directorySweep,
            explanation: "QQ desktop cache. Rebuilt on next launch.",
            source: "mole lib/clean/app_caches.sh:859"
        ),
        target(
            "Feishu cache",
            "Library/Caches/com.feishu.*/*",
            kind: .glob,
            explanation: "Feishu desktop caches across bundle IDs. Rebuilt on demand.",
            source: "mole lib/clean/app_caches.sh:860"
        ),
        target(
            "Feishu service worker cache",
            "Library/Application Support/LarkShell/aha/users/*/profile_explorer/Service Worker/CacheStorage",
            kind: .glob,
            explanation: "Feishu's embedded docs webview precache (the 'aha' explorer profile). Only CacheStorage is targeted, never ScriptCache or login state; a cleared bundle re-precaches on next open.",
            processGuard: feishuGuard,
            source: "mole lib/clean/app_caches.sh:497"
        ),
        target(
            "Lark service worker cache",
            "Library/Application Support/LarkInternational/aha/users/*/profile_explorer/Service Worker/CacheStorage",
            kind: .glob,
            explanation: "Same CacheStorage-only cleanup for the international Lark client.",
            processGuard: feishuGuard,
            source: "mole lib/clean/app_caches.sh:498"
        ),
        target(
            "Notion service worker cache",
            "Library/Application Support/Notion/Partitions/*/Service Worker/CacheStorage",
            kind: .glob,
            explanation: "Notion's Electron partition precache (workspace and page bundles). Only CacheStorage is targeted; pages live on Notion's servers and auth lives in Cookies.",
            processGuard: notionGuard,
            source: "mole lib/clean/app_caches.sh:582"
        ),
        target(
            "Microsoft Teams legacy cache",
            "Library/Application Support/Microsoft/Teams/Cache",
            kind: .directorySweep,
            explanation: "Legacy Teams Electron cache. Rebuilt on next launch.",
            source: "mole lib/clean/app_caches.sh:864"
        ),
        target(
            "Microsoft Teams legacy application cache",
            "Library/Application Support/Microsoft/Teams/Application Cache",
            kind: .directorySweep,
            explanation: "Legacy Teams app cache. Regenerated by the pages that use it.",
            source: "mole lib/clean/app_caches.sh:865"
        ),
        target(
            "Microsoft Teams legacy code cache",
            "Library/Application Support/Microsoft/Teams/Code Cache",
            kind: .directorySweep,
            explanation: "Legacy Teams compiled JS cache. Recompiled on next launch.",
            source: "mole lib/clean/app_caches.sh:866"
        ),
        target(
            "Microsoft Teams legacy GPU cache",
            "Library/Application Support/Microsoft/Teams/GPUCache",
            kind: .directorySweep,
            explanation: "Legacy Teams GPU scratch. Rebuilt by the GPU process.",
            source: "mole lib/clean/app_caches.sh:867"
        ),
        target(
            "Microsoft Teams legacy logs",
            "Library/Application Support/Microsoft/Teams/logs",
            kind: .directorySweep,
            explanation: "Legacy Teams diagnostic logs. Purely informational.",
            source: "mole lib/clean/app_caches.sh:868"
        ),
        target(
            "Microsoft Teams legacy temp files",
            "Library/Application Support/Microsoft/Teams/tmp",
            kind: .directorySweep,
            explanation: "Legacy Teams temp scratch. Recreated per session.",
            source: "mole lib/clean/app_caches.sh:869"
        ),
        target(
            "WeChat logs",
            "Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/log",
            kind: .directorySweep,
            explanation: "WeChat app logs only: chat databases and received files elsewhere in the container are never touched.",
            processGuard: wechatGuard,
            source: "mole lib/clean/app_caches.sh:805"
        ),
        target(
            "WeChat mini program cache",
            "Library/Containers/com.tencent.xinWeChat/Data/.wxapplet/WMPF",
            kind: .directorySweep,
            explanation: "WeChat mini-program framework cache. Rebuilt as mini programs run.",
            processGuard: wechatGuard,
            source: "mole lib/clean/app_caches.sh:806"
        ),
        target(
            "WeCom logs",
            "Library/Containers/com.tencent.WeWorkMac/Data/Library/Application Support/WXWork/Log",
            kind: .directorySweep,
            explanation: "WeCom application logs. Message databases are never touched.",
            processGuard: wecomGuard,
            source: "mole lib/clean/app_caches.sh:815"
        ),
        target(
            "WeCom service worker cache",
            "\(wecomCef)/*/Service Worker/CacheStorage",
            kind: .glob,
            explanation: "Per-profile webview CacheStorage. Only Default and wew_N profiles are eligible; ScriptCache and login state are never touched.",
            processGuard: wecomGuard,
            source: "mole lib/clean/app_caches.sh:833"
        ),
        target(
            "WeCom web cache",
            "\(wecomCef)/*/Cache",
            kind: .glob,
            explanation: "Per-profile Chromium HTTP cache in the cefcache tree.",
            processGuard: wecomGuard,
            source: "mole lib/clean/app_caches.sh:834"
        ),
        target(
            "WeCom code cache",
            "\(wecomCef)/*/Code Cache",
            kind: .glob,
            explanation: "Per-profile compiled JS cache in the cefcache tree. Recompiled on next use.",
            processGuard: wecomGuard,
            source: "mole lib/clean/app_caches.sh:835"
        ),
        target(
            "WeCom GPU cache",
            "\(wecomCef)/*/GPUCache",
            kind: .glob,
            explanation: "Per-profile GPU scratch in the cefcache tree. Rebuilt by the GPU process.",
            processGuard: wecomGuard,
            source: "mole lib/clean/app_caches.sh:836"
        ),
        target(
            "DingTalk iDingTalk cache",
            "Library/Caches/dd.work.exclusive4aliding",
            kind: .directorySweep,
            explanation: "DingTalk client cache. Rebuilt on demand.",
            source: "mole lib/clean/app_caches.sh:875"
        ),
        target(
            "AliLang security component",
            "Library/Caches/com.alibaba.AliLang.osx",
            kind: .directorySweep,
            explanation: "AliLang security component cache. Rebuilt on demand.",
            source: "mole lib/clean/app_caches.sh:876"
        ),
        target(
            "DingTalk logs",
            "Library/Application Support/iDingTalk/log",
            kind: .directorySweep,
            explanation: "DingTalk diagnostic logs. Purely informational.",
            source: "mole lib/clean/app_caches.sh:878"
        ),
        target(
            "DingTalk holmes logs",
            "Library/Application Support/iDingTalk/holmeslogs",
            kind: .directorySweep,
            explanation: "DingTalk holmes-trace logs. Purely informational.",
            source: "mole lib/clean/app_caches.sh:879"
        ),

        // -- Design and creative tools ---------------------------------------------
        target(
            "Sketch cache",
            "Library/Caches/com.bohemiancoding.sketch3",
            kind: .directorySweep,
            explanation: "Sketch app cache. Your .sketch documents are never touched.",
            source: "mole lib/clean/app_caches.sh:899"
        ),
        target(
            "Sketch app cache",
            "Library/Application Support/com.bohemiancoding.sketch3/cache",
            kind: .directorySweep,
            explanation: "Sketch support cache. Rebuilt on next launch.",
            source: "mole lib/clean/app_caches.sh:900"
        ),
        target(
            "Adobe cache",
            "Library/Caches/Adobe",
            kind: .directorySweep,
            explanation: "Shared Adobe cache tree. Rebuilt by the Creative Cloud apps on demand.",
            source: "mole lib/clean/app_caches.sh:901"
        ),
        target(
            "Adobe app caches",
            "Library/Caches/com.adobe.*/*",
            kind: .glob,
            explanation: "Per-app Adobe caches. Rebuilt on demand; project files are untouched.",
            source: "mole lib/clean/app_caches.sh:902"
        ),
        target(
            "Figma cache",
            "Library/Caches/com.figma.Desktop",
            kind: .directorySweep,
            explanation: "Figma desktop cache. Designs live in the cloud; only render scratch is local.",
            source: "mole lib/clean/app_caches.sh:903"
        ),
        target(
            "Adobe media cache files",
            "Library/Application Support/Adobe/Common/Media Cache Files",
            kind: .directorySweep,
            explanation: "Premiere/After Effects conformed-media cache. Regenerated from the original media on next project open.",
            source: "mole lib/clean/app_caches.sh:904"
        ),

        // -- Media players ----------------------------------------------------------
        target(
            "Spotify cache",
            "Library/Caches/com.spotify.client",
            kind: .directorySweep,
            explanation: "Streamed-audio cache. Re-downloaded while streaming; cleaned only when no offline downloads are detected.",
            source: "mole lib/clean/app_caches.sh:1807"
        ),
        target(
            "Apple Music cache",
            "Library/Caches/com.apple.Music",
            kind: .directory,
            explanation: "Music app stream cache. Your library files are never touched.",
            source: "mole lib/clean/app_caches.sh:1809"
        ),
        target(
            "Apple Podcasts cache",
            "Library/Caches/com.apple.podcasts",
            kind: .directory,
            explanation: "Podcasts app cache. Subscriptions and downloaded episodes are untouched.",
            source: "mole lib/clean/app_caches.sh:1810"
        ),
        target(
            "Podcasts streamed media",
            "Library/Containers/com.apple.podcasts/Data/tmp/StreamedMedia",
            kind: .directory,
            explanation: "Temporary streamed-episode files (zombie sparse files). Downloaded episodes are elsewhere and untouched.",
            source: "mole lib/clean/app_caches.sh:1812"
        ),
        target(
            "Podcasts artwork cache",
            "Library/Containers/com.apple.podcasts/Data/tmp/*.heic",
            kind: .glob,
            explanation: "Stale episode artwork scratch files. Re-fetched on demand.",
            source: "mole lib/clean/app_caches.sh:1813"
        ),
        target(
            "Podcasts image cache",
            "Library/Containers/com.apple.podcasts/Data/tmp/*.img",
            kind: .glob,
            explanation: "Stale image cache scratch files. Re-fetched on demand.",
            source: "mole lib/clean/app_caches.sh:1814"
        ),
        target(
            "Podcasts download temp",
            "Library/Containers/com.apple.podcasts/Data/tmp/*CFNetworkDownload*.tmp",
            kind: .glob,
            explanation: "Interrupted CFNetwork download temp files. Safe leftovers.",
            source: "mole lib/clean/app_caches.sh:1815"
        ),
        target(
            "Apple TV cache",
            "Library/Caches/com.apple.TV",
            kind: .directorySweep,
            explanation: "TV app stream/artwork cache. Re-fetched on demand.",
            source: "mole lib/clean/app_caches.sh:1816"
        ),
        target(
            "Plex cache",
            "Library/Caches/tv.plex.player.desktop",
            kind: .directory,
            explanation: "Plex desktop app cache. Media lives on your Plex server.",
            source: "mole lib/clean/app_caches.sh:1817"
        ),
        target(
            "NetEase Music cache",
            "Library/Caches/com.netease.163music",
            kind: .directory,
            explanation: "NetEase Music stream cache. Re-downloaded while streaming.",
            source: "mole lib/clean/app_caches.sh:1818"
        ),
        target(
            "QQ Music cache",
            "Library/Caches/com.tencent.QQMusic",
            kind: .directorySweep,
            explanation: "QQ Music stream cache. Re-downloaded while streaming.",
            source: "mole lib/clean/app_caches.sh:1819"
        ),
        target(
            "QQ Music Mac cache",
            "Library/Caches/com.tencent.QQMusicMac",
            kind: .directorySweep,
            explanation: "QQ Music Mac stream cache. Re-downloaded while streaming.",
            source: "mole lib/clean/app_caches.sh:1820"
        ),
        target(
            "QQ Music streaming cache",
            "Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iRRCache",
            kind: .directorySweep,
            explanation: "Container streaming cache. Offline downloads (iDownloadProxy) are deliberately protected.",
            source: "mole lib/clean/app_caches.sh:1824"
        ),
        target(
            "QQ Music logs",
            "Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iLog",
            kind: .directorySweep,
            explanation: "Container diagnostic logs. Purely informational.",
            source: "mole lib/clean/app_caches.sh:1825"
        ),
        target(
            "QQ Music cache",
            "Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iCache",
            kind: .directorySweep,
            explanation: "Container cache. Offline downloads are protected.",
            source: "mole lib/clean/app_caches.sh:1826"
        ),
        target(
            "QQ Music temp files",
            "Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iTemp",
            kind: .directorySweep,
            explanation: "Container temp scratch. Recreated per session.",
            source: "mole lib/clean/app_caches.sh:1827"
        ),
        target(
            "QQ Music container cache",
            "Library/Containers/com.tencent.QQMusicMac/Data/Library/Caches",
            kind: .directorySweep,
            explanation: "Container Library/Caches. Rebuilt on demand.",
            source: "mole lib/clean/app_caches.sh:1829"
        ),
        target(
            "Kugou Music cache",
            "Library/Caches/com.kugou.mac",
            kind: .directorySweep,
            explanation: "Kugou Music stream cache. Re-downloaded while streaming.",
            source: "mole lib/clean/app_caches.sh:1830"
        ),
        target(
            "Kuwo Music cache",
            "Library/Caches/com.kuwo.mac",
            kind: .directorySweep,
            explanation: "Kuwo Music stream cache. Re-downloaded while streaming.",
            source: "mole lib/clean/app_caches.sh:1831"
        ),

        // -- Video players -----------------------------------------------------------
        target(
            "IINA cache",
            "Library/Caches/com.colliderli.iina",
            kind: .directory,
            explanation: "IINA player cache. Media files are never touched.",
            source: "mole lib/clean/app_caches.sh:1835"
        ),
        target(
            "VLC cache",
            "Library/Caches/org.videolan.vlc",
            kind: .directory,
            explanation: "VLC cache. Media files are never touched.",
            source: "mole lib/clean/app_caches.sh:1836"
        ),
        target(
            "MPV cache",
            "Library/Caches/io.mpv",
            kind: .directory,
            explanation: "mpv player cache. Media files are never touched.",
            source: "mole lib/clean/app_caches.sh:1837"
        ),
        target(
            "iQIYI cache",
            "Library/Caches/com.iqiyi.player",
            kind: .directory,
            explanation: "iQIYI player cache. Re-fetched while streaming.",
            source: "mole lib/clean/app_caches.sh:1838"
        ),
        target(
            "Tencent Video cache",
            "Library/Caches/com.tencent.tenvideo",
            kind: .directory,
            explanation: "Tencent Video player cache. Re-fetched while streaming.",
            source: "mole lib/clean/app_caches.sh:1839"
        ),
        target(
            "Tencent Video old installer",
            "Library/Containers/com.tencent.tenvideo/Data/Library/Application Support/Upgrade",
            kind: .directorySweep,
            explanation: "Superseded installer payloads left by the in-app updater.",
            source: "mole lib/clean/app_caches.sh:1843"
        ),
        target(
            "Tencent Video native cache",
            "Library/Containers/com.tencent.tenvideo/Data/Library/Application Support/VideoNative",
            kind: .directorySweep,
            explanation: "Native renderer cache in the container. Rebuilt on demand.",
            source: "mole lib/clean/app_caches.sh:1844"
        ),
        target(
            "Tencent Video document cache",
            "Library/Containers/com.tencent.tenvideo/Data/Library/Application Support/documentCache",
            kind: .directorySweep,
            explanation: "Document metadata cache in the container. Rebuilt on demand.",
            source: "mole lib/clean/app_caches.sh:1845"
        ),
        target(
            "Bilibili cache",
            "Library/Caches/tv.danmaku.bili",
            kind: .directorySweep,
            explanation: "Bilibili player cache. Re-fetched while streaming.",
            source: "mole lib/clean/app_caches.sh:1847"
        ),
        target(
            "Douyu cache",
            "Library/Caches/com.douyu.*/*",
            kind: .glob,
            explanation: "Douyu streaming caches. Re-fetched while streaming.",
            source: "mole lib/clean/app_caches.sh:1848"
        ),
        target(
            "Huya cache",
            "Library/Caches/com.huya.*/*",
            kind: .glob,
            explanation: "Huya streaming caches. Re-fetched while streaming.",
            source: "mole lib/clean/app_caches.sh:1849"
        ),
        target(
            "SenPlayer video cache",
            "Library/Containers/com.wuziqi.SenPlayer/Data/tmp/videoCache",
            kind: .directorySweep,
            explanation: "SenPlayer streamed-video cache. Re-fetched while streaming.",
            source: "mole lib/clean/app_caches.sh:1850"
        ),
        target(
            "Stremio cache",
            "Library/Caches/smart.stremio*/*",
            kind: .glob,
            explanation: "Stremio streaming caches. Re-fetched while streaming.",
            source: "mole lib/clean/app_caches.sh:1851"
        ),
        target(
            "Stremio server cache",
            "Library/Application Support/stremio/stremio-server/stremio-cache",
            kind: .directorySweep,
            explanation: "Local Stremio streaming server cache. Re-fetched on demand.",
            source: "mole lib/clean/app_caches.sh:1853"
        ),

        // -- Download managers -------------------------------------------------------
        target(
            "Aria2 cache",
            "Library/Caches/net.xmac.aria2gui",
            kind: .directory,
            explanation: "Aria2 GUI cache. Downloads and their metadata are untouched.",
            source: "mole lib/clean/app_caches.sh:1858"
        ),
        target(
            "Transmission cache",
            "Library/Caches/org.m0k.transmission",
            kind: .directory,
            explanation: "Transmission client cache. Torrents and downloaded files are untouched.",
            source: "mole lib/clean/app_caches.sh:1859"
        ),
        target(
            "qBittorrent cache",
            "Library/Caches/com.qbittorrent.qBittorrent",
            kind: .directory,
            explanation: "qBittorrent client cache. Torrents and downloaded files are untouched.",
            source: "mole lib/clean/app_caches.sh:1860"
        ),
        target(
            "Downie cache",
            "Library/Caches/com.downie.Downie-*",
            kind: .glob,
            explanation: "Downie downloader caches. Completed downloads are untouched.",
            source: "mole lib/clean/app_caches.sh:1861"
        ),
        target(
            "Folx cache",
            "Library/Caches/com.folx.*/*",
            kind: .glob,
            explanation: "Folx downloader caches. Completed downloads are untouched.",
            source: "mole lib/clean/app_caches.sh:1862"
        ),
        target(
            "Pacifist cache",
            "Library/Caches/com.charlessoft.pacifist",
            kind: .directorySweep,
            explanation: "Pacifist package-viewer cache. Rebuilt on next package open.",
            source: "mole lib/clean/app_caches.sh:1863"
        ),
        target(
            "NeatDM stale downloads",
            "Library/Application Support/com.NeatDownloadManager",
            kind: .directorySweep,
            explanation: "Numbered incomplete-download segment dirs whose seg.x0 is older than 30 days (their URLs have long expired). The history database is never touched.",
            pruneRule: .staleNumberedSegments(minAgeDays: 30),
            source: "mole lib/clean/app_caches.sh:1871"
        ),

        // -- AI apps -----------------------------------------------------------------
        target(
            "ChatGPT cache",
            "Library/Caches/com.openai.chat",
            kind: .directorySweep,
            explanation: "ChatGPT desktop cache. Conversations are stored server-side.",
            source: "mole lib/clean/app_caches.sh:884"
        ),
        target(
            "Claude desktop cache",
            "Library/Caches/com.anthropic.claudefordesktop",
            kind: .directorySweep,
            explanation: "Claude desktop app cache. Conversations are stored server-side.",
            source: "mole lib/clean/app_caches.sh:885"
        ),
        target(
            "Claude logs",
            "Library/Logs/Claude",
            kind: .directorySweep,
            explanation: "Claude desktop logs. Purely informational.",
            source: "mole lib/clean/app_caches.sh:886"
        ),
        target(
            "LM Studio cache",
            "Library/Caches/com.lmstudio.lmstudio",
            kind: .directorySweep,
            explanation: "LM Studio cache. The legacy ~/.cache/lm-studio root (models/presets/chats) is never cleaned: only this rebuildable cache path.",
            source: "mole lib/clean/app_caches.sh:887"
        ),

        // -- Video editing -------------------------------------------------------------
        target(
            "ScreenFlow cache",
            "Library/Caches/net.telestream.screenflow10",
            kind: .directorySweep,
            explanation: "ScreenFlow cache. Recordings live elsewhere and are untouched.",
            source: "mole lib/clean/app_caches.sh:1113"
        ),
        target(
            "Final Cut Pro cache",
            "Library/Caches/com.apple.FinalCut",
            kind: .directorySweep,
            explanation: "Final Cut Pro app cache. Libraries and media are untouched.",
            source: "mole lib/clean/app_caches.sh:1114"
        ),
        reviewTarget(
            "Final Cut Pro render cache",
            "Movies/*.fcpbundle/*/*/Render Files/High Quality Media",
            kind: .glob,
            explanation: "Generated render media inside FCP libraries. Upstream's scan prunes Original Media, Analysis Files, Motion Templates, backups and library databases, deleting only these documented regenerable render dirs. Review before deleting.",
            processGuard: fcpGuard,
            source: "mole lib/clean/app_caches.sh:955"
        ),
        reviewTarget(
            "Final Cut Pro proxy media",
            "Movies/*.fcpbundle/*/Transcoded Media/Proxy Media",
            kind: .glob,
            explanation: "Generated proxy media inside FCP libraries, same protected-component scan as the render cache. Review before deleting.",
            processGuard: fcpGuard,
            source: "mole lib/clean/app_caches.sh:976"
        ),
        target(
            "DaVinci Resolve cache",
            "Library/Caches/com.blackmagic-design.DaVinciResolve",
            kind: .directorySweep,
            explanation: "DaVinci Resolve app cache. Projects are untouched.",
            source: "mole lib/clean/app_caches.sh:1116"
        ),
        reviewTarget(
            "DaVinci Resolve CacheClip",
            "Movies/CacheClip",
            kind: .directorySweep,
            explanation: "DaVinci Resolve render-cache clips. Regenerated from the source media on next render, but they live under Movies, so review before deleting.",
            source: "mole lib/clean/app_caches.sh:1117"
        ),
        target(
            "Premiere Pro cache",
            "Library/Caches/com.adobe.PremierePro.*",
            kind: .glob,
            explanation: "Premiere Pro caches. Projects and media are untouched.",
            source: "mole lib/clean/app_caches.sh:1118"
        ),
        reviewTarget(
            "JianyingPro recognize scratch",
            "Movies/JianyingPro/User Data/Cache/recognize",
            kind: .directory,
            explanation: "Subtitle-recognition PCM scratch. Upstream's whitelist of regenerable subdirs only; draft projects and downloaded assets are never touched.",
            processGuard: jianyingGuard,
            source: "mole lib/clean/app_caches.sh:1085"
        ),
        reviewTarget(
            "JianyingPro frame thumbnails",
            "Movies/JianyingPro/User Data/Cache/frameThumbnail",
            kind: .directory,
            explanation: "Frame thumbnail cache. Regenerated while editing.",
            processGuard: jianyingGuard,
            source: "mole lib/clean/app_caches.sh:1086"
        ),
        reviewTarget(
            "JianyingPro audio waveforms",
            "Movies/JianyingPro/User Data/Cache/audioWave",
            kind: .directory,
            explanation: "Audio waveform cache. Regenerated while editing.",
            processGuard: jianyingGuard,
            source: "mole lib/clean/app_caches.sh:1087"
        ),
        reviewTarget(
            "JianyingPro algorithm cache",
            "Movies/JianyingPro/User Data/Cache/AlgorithmCache",
            kind: .directory,
            explanation: "Algorithm scratch data. Regenerated on demand.",
            processGuard: jianyingGuard,
            source: "mole lib/clean/app_caches.sh:1088"
        ),
        reviewTarget(
            "JianyingPro ILASDKDB cache",
            "Movies/JianyingPro/User Data/Cache/ILASDKDB",
            kind: .directory,
            explanation: "ILASDK database cache. Regenerated on demand.",
            processGuard: jianyingGuard,
            source: "mole lib/clean/app_caches.sh:1089"
        ),
        reviewTarget(
            "JianyingPro remux cache",
            "Movies/JianyingPro/User Data/Cache/RemuxCache",
            kind: .directory,
            explanation: "Remux scratch. Regenerated on next export.",
            processGuard: jianyingGuard,
            source: "mole lib/clean/app_caches.sh:1090"
        ),
        reviewTarget(
            "JianyingPro prerender cache",
            "Movies/JianyingPro/User Data/Cache/prerender",
            kind: .directory,
            explanation: "Prerender scratch. Regenerated while editing.",
            processGuard: jianyingGuard,
            source: "mole lib/clean/app_caches.sh:1091"
        ),
        reviewTarget(
            "JianyingPro segment prerender cache",
            "Movies/JianyingPro/User Data/Cache/segmentPrerenderCache",
            kind: .directory,
            explanation: "Segment prerender scratch. Regenerated while editing.",
            processGuard: jianyingGuard,
            source: "mole lib/clean/app_caches.sh:1092"
        ),
        reviewTarget(
            "JianyingPro motion blur cache",
            "Movies/JianyingPro/User Data/Cache/MotionBlurCache",
            kind: .directory,
            explanation: "Motion-blur render scratch. Regenerated on demand.",
            processGuard: jianyingGuard,
            source: "mole lib/clean/app_caches.sh:1093"
        ),
        reviewTarget(
            "JianyingPro TTS temp",
            "Movies/JianyingPro/User Data/Cache/ttsTemp",
            kind: .directory,
            explanation: "Text-to-speech scratch. Regenerated on next synthesis.",
            processGuard: jianyingGuard,
            source: "mole lib/clean/app_caches.sh:1094"
        ),
        reviewTarget(
            "JianyingPro tmp",
            "Movies/JianyingPro/User Data/Cache/tmp",
            kind: .directory,
            explanation: "General editor temp scratch. Regenerated per session.",
            processGuard: jianyingGuard,
            source: "mole lib/clean/app_caches.sh:1095"
        ),

        // -- 3D and CAD tools -----------------------------------------------------------
        target(
            "Blender cache",
            "Library/Caches/org.blenderfoundation.blender",
            kind: .directorySweep,
            explanation: "Blender cache. Projects and assets are untouched.",
            source: "mole lib/clean/app_caches.sh:1734"
        ),
        target(
            "Cinema 4D cache",
            "Library/Caches/com.maxon.cinema4d",
            kind: .directorySweep,
            explanation: "Cinema 4D cache. Projects and assets are untouched.",
            source: "mole lib/clean/app_caches.sh:1735"
        ),
        target(
            "Autodesk caches",
            "Library/Caches/com.autodesk.*",
            kind: .glob,
            explanation: "Autodesk reverse-DNS cache trees (children swept first). Skipped while Autodesk helpers run because their SQLite caches stay open.",
            processGuard: autodeskGuard,
            source: "mole lib/clean/app_caches.sh:1739"
        ),
        target(
            "SketchUp cache",
            "Library/Caches/com.sketchup.*",
            kind: .glob,
            explanation: "SketchUp caches. Models are untouched.",
            source: "mole lib/clean/app_caches.sh:1766"
        ),
        target(
            "Autodesk Fusion old bundles",
            "Library/Application Support/Autodesk/webdeploy/production",
            kind: .directorySweep,
            explanation: "Old 40-hex version dirs holding com.autodesk.fusion360 app bundles left by the in-app updater (can be tens of GB). Keeps the alias-resolved current version and any newer staged update; only verified older bundles are removed.",
            processGuard: autodeskGuard,
            pruneRule: .keepCurrentSymlinkTarget,
            source: "mole lib/clean/app_caches.sh:1545"
        ),

        // -- Productivity apps ----------------------------------------------------------
        target(
            "MiaoYan cache",
            "Library/Caches/com.tw93.MiaoYan",
            kind: .directorySweep,
            explanation: "MiaoYan markdown app cache. Notes live elsewhere.",
            source: "mole lib/clean/app_caches.sh:1776"
        ),
        target(
            "Klee cache",
            "Library/Caches/com.klee.desktop",
            kind: .directorySweep,
            explanation: "Klee desktop cache. Rebuilt on demand.",
            source: "mole lib/clean/app_caches.sh:1777"
        ),
        target(
            "Klee desktop cache",
            "Library/Caches/klee_desktop",
            kind: .directorySweep,
            explanation: "Klee desktop cache (alternate bundle). Rebuilt on demand.",
            source: "mole lib/clean/app_caches.sh:1778"
        ),
        target(
            "Ora browser cache",
            "Library/Caches/com.orabrowser.app",
            kind: .directorySweep,
            explanation: "Ora browser cache. Rebuilt as you browse.",
            source: "mole lib/clean/app_caches.sh:1779"
        ),
        target(
            "Filo cache",
            "Library/Caches/com.filo.client",
            kind: .directorySweep,
            explanation: "Filo client cache. Rebuilt on demand.",
            source: "mole lib/clean/app_caches.sh:1780"
        ),
        target(
            "Flomo cache",
            "Library/Caches/com.flomoapp.mac",
            kind: .directorySweep,
            explanation: "Flomo cache. Notes are stored server-side.",
            source: "mole lib/clean/app_caches.sh:1781"
        ),
        target(
            "Quark video cache",
            "Library/Application Support/Quark/Cache/videoCache",
            kind: .directorySweep,
            explanation: "Quark browser video cache. Downloads themselves are untouched.",
            source: "mole lib/clean/app_caches.sh:1782"
        ),
        target(
            "NetNewsWire cache",
            "Library/Containers/com.ranchero.NetNewsWire-Evergreen/Data/Library/Caches",
            kind: .directorySweep,
            explanation: "NetNewsWire RSS cache. Subscriptions live elsewhere.",
            source: "mole lib/clean/app_caches.sh:1783"
        ),
        target(
            "MindNode cache",
            "Library/Containers/com.ideasoncanvas.mindnode/Data/Library/Caches",
            kind: .directorySweep,
            explanation: "MindNode cache. Mind maps live elsewhere.",
            source: "mole lib/clean/app_caches.sh:1784"
        ),
        target(
            "Kaku cache",
            ".cache/kaku",
            kind: .directorySweep,
            explanation: "Kaku app cache. Rebuilt on demand.",
            source: "mole lib/clean/app_caches.sh:1785"
        ),
        target(
            "Spacedrive thumbnail cache",
            "Library/Application Support/spacedrive/thumbnails",
            kind: .directorySweep,
            explanation: "Spacedrive thumbnail cache. Regenerated from the originals.",
            source: "mole lib/clean/app_caches.sh:1786"
        ),
        target(
            "Folo cache",
            "Library/Containers/is.follow/Data/Library/Application Support/Folo/Cache/Cache_Data",
            kind: .directorySweep,
            explanation: "Folo RSS client cache. Subscriptions live elsewhere.",
            source: "mole lib/clean/app_caches.sh:1787"
        ),

        // -- Gaming platforms ------------------------------------------------------------
        target(
            "Steam cache",
            "Library/Caches/com.valvesoftware.steam",
            kind: .directorySweep,
            explanation: "Steam client cache. Installed games are untouched.",
            source: "mole lib/clean/app_caches.sh:1936"
        ),
        target(
            "Steam web cache",
            "Library/Application Support/Steam/htmlcache",
            kind: .directorySweep,
            explanation: "Steam embedded-web cache. Rebuilt on next launch.",
            source: "mole lib/clean/app_caches.sh:1938"
        ),
        target(
            "Steam app cache",
            "Library/Application Support/Steam/appcache",
            kind: .directorySweep,
            explanation: "Steam app metadata cache. Re-fetched by the client.",
            source: "mole lib/clean/app_caches.sh:1939"
        ),
        target(
            "Steam depot cache",
            "Library/Application Support/Steam/depotcache",
            kind: .directorySweep,
            explanation: "Steam depot payload cache. Re-downloaded by the client.",
            source: "mole lib/clean/app_caches.sh:1940"
        ),
        target(
            "Steam shader cache",
            "Library/Application Support/Steam/steamapps/shadercache",
            kind: .directorySweep,
            explanation: "Compiled shader cache. Rebuilt as games render.",
            source: "mole lib/clean/app_caches.sh:1941"
        ),
        target(
            "Steam logs",
            "Library/Application Support/Steam/logs",
            kind: .directorySweep,
            explanation: "Steam client logs. Purely informational.",
            source: "mole lib/clean/app_caches.sh:1942"
        ),
        target(
            "Epic Games cache",
            "Library/Caches/com.epicgames.EpicGamesLauncher",
            kind: .directorySweep,
            explanation: "Epic Games Launcher cache. Installed games are untouched.",
            source: "mole lib/clean/app_caches.sh:1944"
        ),
        target(
            "Battle.net cache",
            "Library/Caches/com.blizzard.Battle.net",
            kind: .directorySweep,
            explanation: "Battle.net launcher cache. Installed games are untouched.",
            source: "mole lib/clean/app_caches.sh:1945"
        ),
        target(
            "Battle.net app cache",
            "Library/Application Support/Battle.net/Cache",
            kind: .directorySweep,
            explanation: "Battle.net app-support cache. Rebuilt on next launch.",
            source: "mole lib/clean/app_caches.sh:1947"
        ),
        target(
            "EA Origin cache",
            "Library/Caches/com.ea.*",
            kind: .glob,
            explanation: "EA app caches. Installed games are untouched.",
            source: "mole lib/clean/app_caches.sh:1949"
        ),
        target(
            "GOG Galaxy cache",
            "Library/Caches/com.gog.galaxy",
            kind: .directorySweep,
            explanation: "GOG Galaxy cache. Installed games are untouched.",
            source: "mole lib/clean/app_caches.sh:1950"
        ),
        target(
            "Riot Games cache",
            "Library/Caches/com.riotgames.*",
            kind: .glob,
            explanation: "Riot client caches. Installed games are untouched.",
            source: "mole lib/clean/app_caches.sh:1951"
        ),
        target(
            "Minecraft logs",
            "Library/Application Support/minecraft/logs",
            kind: .directorySweep,
            explanation: "Minecraft launcher logs. Purely informational.",
            source: "mole lib/clean/app_caches.sh:1953"
        ),
        target(
            "Minecraft crash reports",
            "Library/Application Support/minecraft/crash-reports",
            kind: .directorySweep,
            explanation: "Minecraft crash reports. Purely diagnostic.",
            source: "mole lib/clean/app_caches.sh:1954"
        ),
        target(
            "Minecraft web cache",
            "Library/Application Support/minecraft/webcache",
            kind: .directorySweep,
            explanation: "Minecraft launcher web cache. Rebuilt on next launch.",
            source: "mole lib/clean/app_caches.sh:1955"
        ),
        target(
            "Minecraft web cache 2",
            "Library/Application Support/minecraft/webcache2",
            kind: .directorySweep,
            explanation: "Second-generation launcher web cache. Rebuilt on next launch.",
            source: "mole lib/clean/app_caches.sh:1956"
        ),
        target(
            "Lunar Client game cache",
            ".lunarclient/game-cache",
            kind: .directorySweep,
            explanation: "Lunar Client game cache. Re-fetched by the launcher.",
            source: "mole lib/clean/app_caches.sh:1959"
        ),
        target(
            "Lunar Client launcher cache",
            ".lunarclient/launcher-cache",
            kind: .directorySweep,
            explanation: "Lunar Client launcher cache. Rebuilt on next launch.",
            source: "mole lib/clean/app_caches.sh:1960"
        ),
        target(
            "Lunar Client logs",
            ".lunarclient/logs",
            kind: .directorySweep,
            explanation: "Lunar Client logs. Purely informational.",
            source: "mole lib/clean/app_caches.sh:1961"
        ),
        target(
            "Lunar Client offline logs",
            ".lunarclient/offline/*/logs/*",
            kind: .glob,
            explanation: "Per-version offline logs. Purely informational.",
            source: "mole lib/clean/app_caches.sh:1962"
        ),
        target(
            "Lunar Client offline file logs",
            ".lunarclient/offline/files/*/logs/*",
            kind: .glob,
            explanation: "Per-version offline file logs. Purely informational.",
            source: "mole lib/clean/app_caches.sh:1963"
        ),
        target(
            "PCSX2 cache",
            "Library/Caches/net.pcsx2.PCSX2",
            kind: .directorySweep,
            explanation: "PCSX2 emulator cache. Games and saves are untouched.",
            source: "mole lib/clean/app_caches.sh:1965"
        ),
        target(
            "PCSX2 shader cache",
            "Library/Application Support/PCSX2/cache",
            kind: .directorySweep,
            explanation: "PCSX2 shader cache. Recompiled as games render.",
            source: "mole lib/clean/app_caches.sh:1967"
        ),
        target(
            "PCSX2 logs",
            "Library/Logs/PCSX2",
            kind: .directorySweep,
            explanation: "PCSX2 logs. Purely informational.",
            source: "mole lib/clean/app_caches.sh:1968"
        ),
        target(
            "RPCS3 cache",
            "Library/Caches/net.rpcs3.rpcs3",
            kind: .directorySweep,
            explanation: "RPCS3 emulator cache. Games and saves are untouched.",
            source: "mole lib/clean/app_caches.sh:1971"
        ),
        target(
            "RPCS3 logs",
            "Library/Application Support/rpcs3/logs",
            kind: .directorySweep,
            explanation: "RPCS3 logs. Purely informational.",
            source: "mole lib/clean/app_caches.sh:1972"
        ),

        // -- Translation / dictionary apps ------------------------------------------------
        target(
            "Youdao Dictionary cache",
            "Library/Caches/com.youdao.YoudaoDict",
            kind: .directorySweep,
            explanation: "Youdao Dictionary cache. Wordbooks live elsewhere.",
            source: "mole lib/clean/app_caches.sh:1977"
        ),
        target(
            "Eudict cache",
            "Library/Caches/com.eudic.*",
            kind: .glob,
            explanation: "Eudic dictionary caches. Wordbooks live elsewhere.",
            source: "mole lib/clean/app_caches.sh:1978"
        ),
        target(
            "Bob Translation cache",
            "Library/Caches/com.bob-build.Bob",
            kind: .directorySweep,
            explanation: "Bob translator cache. Rebuilt on demand.",
            source: "mole lib/clean/app_caches.sh:1979"
        ),

        // -- Screenshot / recording tools --------------------------------------------------
        target(
            "CleanShot cache",
            "Library/Caches/com.cleanshot.*",
            kind: .glob,
            explanation: "CleanShot caches. Saved screenshots live elsewhere.",
            source: "mole lib/clean/app_caches.sh:1983"
        ),
        target(
            "Camo cache",
            "Library/Caches/com.reincubate.camo",
            kind: .directorySweep,
            explanation: "Camo camera cache. Recordings live elsewhere.",
            source: "mole lib/clean/app_caches.sh:1984"
        ),
        target(
            "Xnip cache",
            "Library/Caches/com.xnipapp.xnip",
            kind: .directorySweep,
            explanation: "Xnip screenshot cache. Saved shots live elsewhere.",
            source: "mole lib/clean/app_caches.sh:1985"
        ),

        // -- Email clients -------------------------------------------------------------------
        target(
            "Spark cache",
            "Library/Caches/com.readdle.smartemail-Mac",
            kind: .directorySweep,
            explanation: "Spark mail cache. Mail data lives elsewhere.",
            source: "mole lib/clean/app_caches.sh:1989"
        ),
        target(
            "Airmail cache",
            "Library/Caches/com.airmail.*",
            kind: .glob,
            explanation: "Airmail caches. Mail data lives elsewhere.",
            source: "mole lib/clean/app_caches.sh:1990"
        ),

        // -- Task management apps -------------------------------------------------------------
        target(
            "Todoist cache",
            "Library/Caches/com.todoist.mac.Todoist",
            kind: .directorySweep,
            explanation: "Todoist cache. Tasks are stored server-side.",
            source: "mole lib/clean/app_caches.sh:1994"
        ),
        target(
            "Any.do cache",
            "Library/Caches/com.any.do.*",
            kind: .glob,
            explanation: "Any.do caches. Tasks are stored server-side.",
            source: "mole lib/clean/app_caches.sh:1995"
        ),

        // -- Shell / terminal utilities ---------------------------------------------------------
        target(
            "Zsh completion cache",
            ".zcompdump*",
            kind: .glob,
            explanation: "Zsh completion dump files. Regenerated on next shell start.",
            source: "mole lib/clean/app_caches.sh:1999"
        ),
        target(
            "less history",
            ".lesshst",
            kind: .file,
            explanation: "less command history. Purely convenience data.",
            source: "mole lib/clean/app_caches.sh:2000"
        ),
        target(
            "Vim temporary files",
            ".viminfo.tmp",
            kind: .file,
            explanation: "Vim info temp file. Purely scratch.",
            source: "mole lib/clean/app_caches.sh:2001"
        ),
        target(
            "wget HSTS cache",
            ".wget-hsts",
            kind: .file,
            explanation: "wget HSTS host cache. Re-learned on next download.",
            source: "mole lib/clean/app_caches.sh:2002"
        ),
        target(
            "Cacher logs",
            ".cacher/logs",
            kind: .directorySweep,
            explanation: "Cacher logs. Purely informational.",
            source: "mole lib/clean/app_caches.sh:2003"
        ),
        target(
            "Kite logs",
            ".kite/logs",
            kind: .directorySweep,
            explanation: "Kite logs. Purely informational.",
            source: "mole lib/clean/app_caches.sh:2004"
        ),
        target(
            "Warp cache",
            "Library/Caches/dev.warp.Warp-Stable",
            kind: .directorySweep,
            explanation: "Warp terminal cache. Sessions live elsewhere.",
            source: "mole lib/clean/app_caches.sh:2005"
        ),
        target(
            "Warp log",
            "Library/Logs/warp.log",
            kind: .file,
            explanation: "Warp terminal log. Purely informational.",
            source: "mole lib/clean/app_caches.sh:2006"
        ),
        target(
            "Warp Sentry crash reports",
            "Library/Caches/SentryCrash/Warp",
            kind: .directorySweep,
            explanation: "Warp crash reports. Purely diagnostic.",
            source: "mole lib/clean/app_caches.sh:2007"
        ),
        target(
            "Ghostty cache",
            "Library/Caches/com.mitchellh.ghostty",
            kind: .directorySweep,
            explanation: "Ghostty terminal cache. Rebuilt on next launch.",
            source: "mole lib/clean/app_caches.sh:2008"
        ),

        // -- Input methods and system utilities --------------------------------------------------
        target(
            "Input Source Pro cache",
            "Library/Caches/com.runjuu.Input-Source-Pro",
            kind: .directorySweep,
            explanation: "Input Source Pro cache. Rebuilt on next launch.",
            source: "mole lib/clean/app_caches.sh:2012"
        ),
        target(
            "WakaTime cache",
            "Library/Caches/macos-wakatime.WakaTime",
            kind: .directorySweep,
            explanation: "WakaTime cache. Stats live server-side.",
            source: "mole lib/clean/app_caches.sh:2013"
        ),
        target(
            "WeType image cache",
            "Library/Application Support/WeType/com.onevcat.Kingfisher.ImageCache.WeType",
            kind: .directorySweep,
            explanation: "WeType image cache, not the engine or user dictionary.",
            source: "mole lib/clean/app_caches.sh:2015"
        ),
        target(
            "WeType dict update cache",
            "Library/Application Support/WeType/DictUpdate",
            kind: .directorySweep,
            explanation: "WeType dictionary update downloads. The user dictionary is untouched.",
            source: "mole lib/clean/app_caches.sh:2016"
        ),
        target(
            "mihomo-party cache",
            "Library/Application Support/mihomo-party/Cache",
            kind: .directorySweep,
            explanation: "mihomo-party Electron cache. Configs live elsewhere.",
            source: "mole lib/clean/app_caches.sh:2019"
        ),
        target(
            "mihomo-party code cache",
            "Library/Application Support/mihomo-party/Code Cache",
            kind: .directorySweep,
            explanation: "mihomo-party compiled bytecode. Recompiled on launch.",
            source: "mole lib/clean/app_caches.sh:2020"
        ),
        target(
            "mihomo-party GPU cache",
            "Library/Application Support/mihomo-party/GPUCache",
            kind: .directorySweep,
            explanation: "mihomo-party GPU scratch. Rebuilt by the GPU process.",
            source: "mole lib/clean/app_caches.sh:2021"
        ),
        target(
            "mihomo-party Dawn cache",
            "Library/Application Support/mihomo-party/DawnGraphiteCache",
            kind: .directorySweep,
            explanation: "mihomo-party Dawn Graphite cache. Regenerated on demand.",
            source: "mole lib/clean/app_caches.sh:2022"
        ),
        target(
            "mihomo-party WebGPU cache",
            "Library/Application Support/mihomo-party/DawnWebGPUCache",
            kind: .directorySweep,
            explanation: "mihomo-party WebGPU cache. Regenerated on demand.",
            source: "mole lib/clean/app_caches.sh:2023"
        ),
        target(
            "mihomo-party logs",
            "Library/Application Support/mihomo-party/logs",
            kind: .directorySweep,
            explanation: "mihomo-party logs. Purely informational.",
            source: "mole lib/clean/app_caches.sh:2024"
        ),
        target(
            "Stash cache",
            "Library/Caches/ws.stash.app.mac",
            kind: .directorySweep,
            explanation: "Stash proxy tool cache. Configs live elsewhere.",
            source: "mole lib/clean/app_caches.sh:2027"
        ),

        // -- Note-taking apps ----------------------------------------------------------------------
        target(
            "Notion cache",
            "Library/Caches/notion.id",
            kind: .directorySweep,
            explanation: "Notion desktop cache. Notes are stored server-side.",
            source: "mole lib/clean/app_caches.sh:2031"
        ),
        target(
            "Obsidian cache",
            "Library/Caches/md.obsidian",
            kind: .directorySweep,
            explanation: "Obsidian cache. Vault contents live elsewhere.",
            source: "mole lib/clean/app_caches.sh:2032"
        ),
        target(
            "Logseq cache",
            "Library/Caches/com.logseq.*",
            kind: .glob,
            explanation: "Logseq caches. Notes live elsewhere.",
            source: "mole lib/clean/app_caches.sh:2033"
        ),
        target(
            "Bear cache",
            "Library/Caches/com.bear-writer.*",
            kind: .glob,
            explanation: "Bear caches. Notes live elsewhere.",
            source: "mole lib/clean/app_caches.sh:2034"
        ),
        target(
            "Evernote cache",
            "Library/Caches/com.evernote.*",
            kind: .glob,
            explanation: "Evernote caches. Notes are stored server-side.",
            source: "mole lib/clean/app_caches.sh:2035"
        ),
        target(
            "Yinxiang Note cache",
            "Library/Caches/com.yinxiang.*",
            kind: .glob,
            explanation: "Yinxiang (Evernote CN) caches. Notes are stored server-side.",
            source: "mole lib/clean/app_caches.sh:2036"
        ),

        // -- Launchers and automation tools ---------------------------------------------------------
        target(
            "Alfred cache",
            "Library/Caches/com.runningwithcrayons.Alfred",
            kind: .directorySweep,
            explanation: "Alfred cache. Workflows live elsewhere.",
            source: "mole lib/clean/app_caches.sh:2040"
        ),
        target(
            "The Unarchiver cache",
            "Library/Caches/cx.c3.theunarchiver",
            kind: .directorySweep,
            explanation: "The Unarchiver cache. Extracted files live elsewhere.",
            source: "mole lib/clean/app_caches.sh:2041"
        ),

        // -- Remote desktop tools ---------------------------------------------------------------------
        target(
            "TeamViewer cache",
            "Library/Caches/com.teamviewer.*",
            kind: .glob,
            explanation: "TeamViewer caches. Session state lives elsewhere.",
            source: "mole lib/clean/app_caches.sh:2045"
        ),
        target(
            "AnyDesk cache",
            "Library/Caches/com.anydesk.*",
            kind: .glob,
            explanation: "AnyDesk caches. Session state lives elsewhere.",
            source: "mole lib/clean/app_caches.sh:2046"
        ),
        target(
            "ToDesk cache",
            "Library/Caches/com.todesk.*",
            kind: .glob,
            explanation: "ToDesk caches. Session state lives elsewhere.",
            source: "mole lib/clean/app_caches.sh:2047"
        ),
        target(
            "Sunlogin cache",
            "Library/Caches/com.sunlogin.*",
            kind: .glob,
            explanation: "Sunlogin caches. Session state lives elsewhere.",
            source: "mole lib/clean/app_caches.sh:2048"
        ),
    ]
}
