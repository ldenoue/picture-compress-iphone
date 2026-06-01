# Photo Squeeze

A simple SwiftUI iOS app that scans the user's Photos library, estimates how much storage could be saved by resizing images to a configurable maximum side length, and can create compressed replacements.

## Important PhotoKit behavior

iOS does not let third-party apps rewrite the original file for a Photos asset in place. The app uses the closest public-API workflow:

1. Read the original image data.
2. Resize and re-encode it as JPEG while copying image metadata.
3. Prepare a bounded batch of replacement files in the app's temporary directory.
4. Ask Photos to create the new assets with the original creation dates and locations.
5. Add the replacements back to user albums that can be modified.
6. Delete the original assets in the same Photos change.
7. Remove that batch's temporary files, then continue with the next batch.

The replacement flow intentionally avoids preparing the whole library at once. It caps each batch at 100 photos or about 200 MB of temporary JPEGs, whichever comes first. That means iOS may show more than one delete confirmation for a very large library, but it should not ask once per photo and it avoids filling storage with a full-library temporary copy.

This keeps normal Photos timeline sorting correct because the replacement receives the original `creationDate`. Smart albums, some system-only state, Live Photo motion data, RAW originals, and animated GIF behavior are not rewritten by this workflow, so the app skips Live Photos, RAW images, and GIFs.

## Open in Xcode

Open `PictureCompress.xcodeproj`, select your development team in Signing & Capabilities, then run on a real iPhone. The simulator has no useful Photos library for this workflow.
