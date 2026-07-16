---
title: CommandBloom
description: A native, open-source Actions Ring alternative for Logitech MX Master 4 on macOS.
---
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="description" content="A native, open-source Actions Ring alternative for Logitech MX Master 4 on macOS.">
    <title>CommandBloom — Actions Ring for macOS</title>
    <link rel="icon" href="{{ '/assets/command-bloom-mark.svg' | relative_url }}" type="image/svg+xml">
    <link rel="stylesheet" href="{{ '/assets/site.css' | relative_url }}">
  </head>
  <body>
    <main>
      <header class="hero">
        <img class="mark" src="{{ '/assets/command-bloom-mark.svg' | relative_url }}" alt="CommandBloom mark">
        <p class="eyebrow">Native macOS · Open source</p>
        <h1>CommandBloom</h1>
        <p class="lede">An Actions Ring alternative for the Logitech MX Master 4, built around its Haptic Sense Panel.</p>
        <div class="links">
          <a class="primary" href="{{ site.github.repository_url }}">View source</a>
          <a href="{{ site.github.repository_url }}/blob/main/docs/technical.md">Technical reference</a>
        </div>
      </header>

      <figure class="demo">
        <img src="{{ '/assets/command-bloom-demo.gif' | relative_url }}" alt="CommandBloom radial launcher running on macOS">
      </figure>

      <section class="intro">
        <h2>Your mouse, your actions.</h2>
        <p>Launch apps, send shortcuts, open URLs, and run app-specific commands from a native radial overlay. Everything stays local.</p>
        <p>Configuration is intentionally CLI-only and designed for a coding agent to handle.</p>
      </section>

      <section>
        <div class="section-heading">
          <p class="eyebrow">Source builds only</p>
          <h2>Build and install</h2>
        </div>
        <p>Requires macOS 26, Swift 6.2, an MX Master 4, and a stable code-signing identity.</p>
        <pre><code>git clone https://github.com/bra1nDump/command-bloom.git
cd command-bloom
swift build -c release
codesign --force --sign "YOUR STABLE SIGNING IDENTITY" \
  --identifier com.logiliquid.controls.daemon --options runtime \
  .build/release/logi-liquid-daemon

launchctl disable "gui/$(id -u)/com.logi.cp-dev-mgr"
launchctl bootout "gui/$(id -u)/com.logi.cp-dev-mgr" 2&gt;/dev/null || true
./.build/release/logi-liquid service install
./.build/release/logi-liquid-overlay</code></pre>
        <p><code>security find-identity -v -p codesigning</code> lists usable identities. A local self-signed <strong>Code Signing</strong> certificate is sufficient.</p>
        <p>Logi Options+ and CommandBloom cannot own the Sense Panel together. These commands unload only its device manager.</p>
      </section>

      <section>
        <div class="section-heading">
          <p class="eyebrow">One-time setup</p>
          <h2>Grant permissions</h2>
        </div>
        <p>In <strong>System Settings → Privacy &amp; Security</strong>, grant <strong>Input Monitoring</strong> and <strong>Accessibility</strong> to:</p>
        <pre><code>~/Library/Application Support/Logi Liquid Controls/bin/logi-liquid-daemon</code></pre>
        <pre><code>./.build/release/logi-liquid service restart
./.build/release/logi-liquid doctor</code></pre>
      </section>

      <section class="agent-card">
        <p class="eyebrow">Agent configured</p>
        <h2>Describe the layout you want.</h2>
        <blockquote>Configure CommandBloom with Spotify on top, Telegram on the right, and Command-B in the bottom zone when Xcode is active. Inspect <code>./.build/release/logi-liquid help</code>, apply the <code>actions put-*</code> commands, and verify the resolved Xcode layout.</blockquote>
      </section>

      <footer>
        <p>CommandBloom is an independent, unofficial open-source project. It is not affiliated with, endorsed by, or sponsored by Logitech. Logitech, Logi, MX Master, and Actions Ring are trademarks of their respective owners.</p>
      </footer>
    </main>
  </body>
</html>
