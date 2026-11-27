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

5. Package a disk image next to the zip:

   ```sh
   V=$(cat VERSION); S=$(mktemp -d)
   cp -R build/Folio.app "$S/" && ln -s /Applications "$S/Applications"
   hdiutil create -volname "Folio $V" -srcfolder "$S" -format UDZO -fs APFS "build/Folio-$V.dmg"
   cp "build/Folio-$V.dmg" build/Folio.dmg
   (cd build && shasum -a 256 "Folio-$V.zip" "Folio-$V.dmg" > SHA256SUMS.txt)
   ```

6. Tag and publish:

   ```sh
   git tag "v$V" && git push --tags
   gh release create "v$V" "build/Folio-$V.dmg" "build/Folio-$V.zip" build/Folio.dmg build/SHA256SUMS.txt \
     --title "Folio $V" --notes-file <(sed -n "/## \[$V\]/,/## \[/p" CHANGELOG.md | sed '$d')
   ```

The landing page's Download button points at `releases/latest/download/Folio.dmg`, so it picks up the new build automatically. Keep uploading the unversioned `Folio.dmg`.

Until a release is signed with a Developer ID and notarized (step 4), say so in the release notes and keep the README's *Install* section, which explains **Open Anyway**.
