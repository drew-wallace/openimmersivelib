# OpenImmersiveLib

_A free and open source spatial & immersive video player Swift Package for visionOS._

Maintained by [Anthony Maës](https://www.linkedin.com/in/portemantho/) & [Acute Immersive](https://acuteimmersive.com/), derived from [Spatial Player](https://github.com/mikeswanson/SpatialPlayer/) by [Mike Swanson](https://blog.mikeswanson.com/).

Built for Swift 6.2 & visionOS 26.

Refer to the main [OpenImmersive repo](https://github.com/acuteimmersive/openimmersive) for more details.

## Development

The native dependency is checksum pinned. To rebuild it from pinned sources with
Xcode 26+ (including visionOS SDKs), Swift 6.2 and Python 3.12+:

```sh
python3 Scripts/build_native.py
python3 Scripts/test_core.py
python3 Scripts/test_transport.py
```

The core and transport host harnesses test the production sources without adding
macOS to the public visionOS UI product. Decoder fixtures are generated from
pinned conformance material; no user media is included. See
[dependency notices](THIRD_PARTY_NOTICES.md) for release and relinking materials.
