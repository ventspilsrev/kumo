# Building Kumo

There is no Mac involved. GitHub builds the app on its own Mac computers every
time code is pushed, and publishes an `.ipa` file you install with TrollStore.

## One-time setup

1. Create a free account at https://github.com/signup (in any browser).
2. On the PC, open a **new** terminal (so it finds the tools) and run:

   ```
   gh auth login
   ```

   Answer the questions like this:
   - Where do you use GitHub? **GitHub.com**
   - Preferred protocol? **HTTPS**
   - Authenticate Git with your GitHub credentials? **Yes**
   - How would you like to authenticate? **Login with a web browser**

   It shows an 8-character code and opens the browser. Sign in, type the code,
   press **Authorize**. The terminal then says "Logged in as ...".

After that, the assistant can create the repository, push code and read build
logs for you.

## Every build

1. Code is pushed to the `main` branch (the assistant does this).
2. GitHub runs the workflow in `.github/workflows/build.yml`:
   - picks Xcode 16.4 (still able to build for iOS 15)
   - `xcodegen generate` creates the Xcode project from `project.yml`
   - `xcodebuild` compiles without Apple code signing
   - `ldid -S` fake-signs the app so TrollStore accepts it
   - the app is zipped into `Kumo.ipa` and published as a Release
3. A build takes roughly 3 to 6 minutes.

## Installing on the iPad

1. On the iPad, open Safari and go to the repository's **Releases** page
   (`https://github.com/<your-name>/kumo/releases`).
2. Under the newest build, tap **Kumo.ipa** and choose **Download**.
3. Open the **Files** app, go to **Downloads**, press and hold **Kumo.ipa**,
   tap **Share**, then **TrollStore**.
4. In TrollStore tap **Install**. For later builds the same steps update the
   app and keep your data, because the app identifier never changes.

## If a build fails

The red X on the repository's **Actions** tab opens the log. The step named
"Build (errors and warnings only)" lists the compile errors.

## Testing extensions on the PC

```
node harness/run.js https://thenetsky.github.io/netskys-extensions/0.8 MangaKatana one piece
```
