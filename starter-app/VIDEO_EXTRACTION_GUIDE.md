# Video Extraction Fix Guide (YouTube & Instagram)

> **Last Updated:** February 2026  
> **Status:** Working with residential proxy

This document explains how to fix YouTube and Instagram extraction issues on cloud hosting platforms like Render, Railway, AWS, etc.

---

## The Problem

Both YouTube and Instagram have implemented aggressive anti-bot measures that block video extraction from cloud/datacenter IPs:

### YouTube

1. **Datacenter IP Blocking**: Blocks all major cloud provider IP ranges (AWS, GCP, Render, Railway, Heroku, etc.)
2. **Bot Detection**: Returns "Sign in to confirm you're not a bot"
3. **PO Token Requirements**: Some yt-dlp clients now require "Proof of Origin" tokens
4. **SABR Streaming**: Forces certain clients to use SABR streaming which breaks downloads

### Instagram

1. **Datacenter IP Blocking**: Same as YouTube - blocks cloud provider IPs
2. **Authentication Required**: Most content requires login/cookies
3. **Rate Limiting**: Aggressive rate limits on automated requests

---

## The Solution

### Requirements by Platform


| Platform      | Residential Proxy | Special Client | Cookies      |
| ------------- | ----------------- | -------------- | ------------ |
| **YouTube**   | ✅ Required        | ✅ `android_vr` | ❌ Not needed |
| **Instagram** | ✅ Required        | ❌ Not needed   | ✅ Required   |
| **TikTok**    | ❌ Not needed      | ❌ Not needed   | ❌ Not needed |


---

## 1. Residential Proxy Setup (Required for YouTube & Instagram)

YouTube and Instagram only allow requests from residential IP addresses. You need a rotating residential proxy service.

**Recommended: [Webshare.io**](https://www.webshare.io/)

- Cost: ~$5-10/month for rotating residential proxies
- Setup:
  1. Sign up at [https://www.webshare.io/](https://www.webshare.io/)
  2. Purchase "Rotating Residential" proxies
  3. Get your proxy credentials from the dashboard
  4. Format: `http://username:password@p.webshare.io:80`

### Environment Variable

Add to your environment (Render, Railway, .env, etc.):

```bash
YOUTUBE_PROXY=http://username:password@p.webshare.io:80
```

> **Note:** We use `YOUTUBE_PROXY` for both YouTube and Instagram since they share the same proxy.

---

## 2. YouTube-Specific: Use `android_vr` Client

Not all yt-dlp clients work with YouTube. Here's the current status (February 2026):


| Client       | PO Token Required | Works with Proxy | Notes                              |
| ------------ | ----------------- | ---------------- | ---------------------------------- |
| `android_vr` | **No**            | **Yes**          | ✅ Recommended                      |
| `tv`         | No                | Yes              | May have DRM issues if overused    |
| `ios`        | Yes (GVS)         | No               | Requires PO Token we can't provide |
| `web`        | Yes (GVS/Subs)    | No               | Only SABR formats available        |
| `mweb`       | Yes (GVS)         | No               | Requires PO Token                  |


**Use** `android_vr` - it doesn't require a PO Token and works well with residential proxies.

---

## 3. Instagram-Specific: Cookies Required

Instagram requires authentication for most content. You need to provide cookies from a logged-in browser session.

### Getting Instagram Cookies

1. **Install a browser extension** like "Get cookies.txt LOCALLY" (Chrome/Firefox)
2. **Log into Instagram** in your browser
3. **Export cookies** for instagram.com in Netscape format
4. **Add to environment** as `INSTAGRAM_COOKIES`

### Environment Variable

```bash
# Option 1: Paste the entire cookie file content
INSTAGRAM_COOKIES="# Netscape HTTP Cookie File
.instagram.com	TRUE	/	TRUE	1234567890	sessionid	abc123...
..."

# Option 2: Path to cookie file (local development)
INSTAGRAM_COOKIES=/path/to/instagram_cookies.txt
```

---

## Implementation (Python/recipe-api)

### Config

```python
# app/config.py
class Settings(BaseSettings):
    # Residential proxy for YouTube and Instagram
    youtube_proxy: str | None = None
    
    # Instagram cookies for authentication
    instagram_cookies: str | None = None
```

### YouTube Extraction

```python
# YouTube: Use proxy + android_vr client
if platform == "youtube" and settings.youtube_proxy:
    command.extend([
        "--proxy", settings.youtube_proxy,
        "--extractor-args", "youtube:player_client=android_vr",
    ])
```

### Instagram Extraction

```python
# Instagram: Use proxy + cookies
if platform == "instagram":
    if settings.youtube_proxy:
        command.extend(["--proxy", settings.youtube_proxy])
    
    cookies_path = get_instagram_cookies_path()
    if cookies_path:
        command.extend(["--cookies", cookies_path])
```

### Full Example

```python
async def download_audio(url: str, platform: str) -> str:
    command = [
        "yt-dlp",
        "--extract-audio",
        "--audio-format", "mp3",
        "--output", output_path,
    ]
    
    # YouTube: proxy + android_vr client
    if platform == "youtube" and settings.youtube_proxy:
        command.extend([
            "--proxy", settings.youtube_proxy,
            "--extractor-args", "youtube:player_client=android_vr",
        ])
    
    # Instagram: proxy + cookies
    if platform == "instagram":
        if settings.youtube_proxy:
            command.extend(["--proxy", settings.youtube_proxy])
        if cookies_path := get_instagram_cookies_path():
            command.extend(["--cookies", cookies_path])
    
    # TikTok: no special handling needed
    
    command.append(url)
    
    process = await asyncio.create_subprocess_exec(*command, ...)
    await process.communicate()
    return output_path
```

---

## Key yt-dlp Arguments


| Argument                                              | Purpose                         | Platform           |
| ----------------------------------------------------- | ------------------------------- | ------------------ |
| `--proxy URL`                                         | Route through residential proxy | YouTube, Instagram |
| `--extractor-args "youtube:player_client=android_vr"` | Use VR client (no PO Token)     | YouTube only       |
| `--cookies FILE`                                      | Authenticate with cookies       | Instagram          |


---

## Troubleshooting

### YouTube Issues

#### "Sign in to confirm you're not a bot"

- Your proxy isn't working or isn't residential
- Check proxy credentials
- Verify proxy is "rotating residential" not "datacenter"

#### "ios client requires GVS PO Token"

- Switch to `android_vr` client
- Don't use `ios`, `web`, or `mweb` clients

#### "YouTube is forcing SABR streaming"

- Switch from `tv` or `web` client to `android_vr`

### Instagram Issues

#### "Login required" or "Please log in"

- Cookies are missing or expired
- Re-export fresh cookies from browser
- Ensure you're logged into Instagram when exporting

#### "Rate limited" or HTTP 429

- Too many requests
- Wait and try again later
- Consider using multiple accounts/cookies

#### "This content isn't available"

- The post is private or deleted
- Account may need to follow the creator

### General Issues

#### "No supported JavaScript runtime"

- Install Node.js in your Docker image
- Add `--js-runtimes node` to yt-dlp commands (YouTube)

#### Proxy connection errors

- Verify proxy URL format: `http://user:pass@host:port`
- Check your Webshare dashboard for usage limits
- Try a different proxy from the pool

---

## Cost Estimate


| Service                       | Cost         | Notes                            |
| ----------------------------- | ------------ | -------------------------------- |
| Webshare Rotating Residential | ~$5-10/month | Required for YouTube & Instagram |


This is the minimum viable solution for cloud-hosted extraction.

---

## Verification Logs

When working correctly, you should see logs like:

### YouTube

```
📱 Detected platform: youtube
🔄 Using YouTube proxy for extraction
✅ Audio downloaded: /tmp/recipe-audio-xxx/audio.mp3
```

### Instagram

```
📱 Detected platform: instagram
🔄 Using residential proxy for Instagram extraction
🍪 Using Instagram cookies from: /tmp/instagram_cookies.txt
✅ Audio downloaded: /tmp/recipe-audio-xxx/audio.mp3
```

---

## References

- [yt-dlp PO Token Guide](https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide)
- [yt-dlp YouTube Extractor Wiki](https://github.com/yt-dlp/yt-dlp/wiki/Extractors#youtube)
- [yt-dlp EJS (JavaScript) Wiki](https://github.com/yt-dlp/yt-dlp/wiki/EJS)
- [Webshare.io](https://www.webshare.io/)

---

## Summary


| Platform      | Setup Required                        |
| ------------- | ------------------------------------- |
| **YouTube**   | `YOUTUBE_PROXY` + `android_vr` client |
| **Instagram** | `YOUTUBE_PROXY` + `INSTAGRAM_COOKIES` |
| **TikTok**    | None - works out of the box           |


1. Get a **rotating residential proxy** (Webshare ~$5-10/mo)
2. Set `YOUTUBE_PROXY` environment variable
3. For Instagram, also set `INSTAGRAM_COOKIES`
4. YouTube uses `--extractor-args "youtube:player_client=android_vr"`
5. Instagram uses `--cookies` with the cookie file

