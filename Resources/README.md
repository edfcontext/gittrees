# Resources

`Scripts/build-app.sh` looks for the app icon in this order:

1. `Resources/AppIcon.png`
2. `image.png` in the project root

A square PNG of at least 512×512 works best, with the macOS squircle and its margin
already part of the artwork. Without one, the app builds with the generic macOS icon.
