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
            explanation: "WeChat app logs only — chat databases and received files elsewhere in the container are never touched.",
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
    ]
}
