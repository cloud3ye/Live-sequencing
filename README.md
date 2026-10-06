# LiveSequence

Takes real Live Photos automatically at random 0.8–3 s gaps so the motion clips
overlap, finds Live Photo sequences in your library, and stitches the original
motion clips into one video.

## Get it on your iPhone (Windows, no Mac)

### 1. Put the code on GitHub
1. Sign in at github.com and click **New repository**. Name it `LiveSequence`.
   Public is simplest (free unlimited builds); private works too but uses free monthly minutes.
2. On the new repo page, click **uploading an existing file**.
3. Drag in everything inside this folder — `Sources`, `.github`, `project.yml`, `README.md` —
   and click **Commit changes**.
   - Check the repo shows a `.github/workflows/build.yml` file. If the `.github`
     folder didn't upload, click **Add file → Create new file**, type
     `.github/workflows/build.yml` as the name, paste that file's contents and commit.

### 2. Let GitHub build it
1. Open the **Actions** tab. A "Build IPA" run starts automatically after each commit
   (or click **Build IPA → Run workflow**).
2. It takes about 5–10 minutes. When it shows a green tick, open the run and download
   **LiveSequence-ipa** at the bottom. Unzip it to get `LiveSequence.ipa`.

### 3. Install with Sideloadly
1. Install iTunes (from Apple's website, not the Microsoft Store version) and Sideloadly.
2. Plug in your iPhone and tap **Trust** on the phone.
3. In Sideloadly, drag in `LiveSequence.ipa`, enter your Apple ID and click **Start**.
4. On the iPhone: **Settings → General → VPN & Device Management**, tap your Apple ID
   and **Trust**.
5. If iOS asks, turn on **Settings → Privacy & Security → Developer Mode** and restart.

The app stops opening after 7 days. Repeat step 3 to refresh it (your photos are unaffected).

## Changing the app
Edit a file in `Sources` on GitHub (pencil icon) and commit. A new build runs
automatically; download and install it the same way.
