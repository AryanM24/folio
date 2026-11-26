# Releasing

1. Update `VERSION` (semantic versioning) and move the `Unreleased` entries in `CHANGELOG.md` under the new version with today's date.
2. Run the checks:

   ```sh
   make test
   make launch-time        # launch and quit must both stay under 1 s
   ```

3. Build the release app: `make app` produces `build/Folio.app`, ad-hoc signed.
4. Sign with a Developer ID and notarize, so people can open it without Gatekeeper warnings:

   ```sh
   codesign --force --options runtime --timestamp \
     --entitlements Resources/Folio.entitlements \
     --sign "Developer ID Application: <Name> (<TEAMID>)" build/Folio.app
   ditto -c -k --keepParent build/Folio.app build/Folio.zip
   xcrun notarytool submit build/Folio.zip --keychain-profile <profile> --wait
   xcrun stapler staple build/Folio.app
   ditto -c -k --keepParent build/Folio.app "build/Folio-$(cat VERSION).zip"
   ```

5. Tag and publish:

   ```sh
   git tag "v$(cat VERSION)" && git push --tags
   gh release create "v$(cat VERSION)" "build/Folio-$(cat VERSION).zip" --notes-file <(sed -n "/## \[$(cat VERSION)\]/,/## \[/p" CHANGELOG.md | sed '$d')
   ```

The landing page links to `releases/latest`, so it picks up the new build automatically.
