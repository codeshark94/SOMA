# Third-party notices

## obsbot-mcp protocol research

The OBSBOT open UVC/XU transport in `Sources/SOMANativeTracking` uses protocol
descriptions and macOS USB-control research published by Michael Jordan in
[obsbot-mcp](https://github.com/lxman/obsbot-mcp). That project is MIT licensed:

```text
MIT License

Copyright (c) 2026 Michael Jordan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Ultralytics YOLO11n

`Sources/SOMASubconscious/Resources/YOLO11n.mlpackage` is an exported
Ultralytics YOLO11n COCO object-detection model. Its embedded Core ML metadata
identifies Ultralytics and the AGPL-3.0 license. Ultralytics documents YOLO11
under AGPL-3.0 or a separate Enterprise license. The bundled package remains
subject to those terms; see the [Ultralytics license page](https://docs.ultralytics.com/license/).

## Silero VAD

`Sources/SOMAVADModel/Resources/SileroVAD256ms.mlmodelc` is a Core ML
conversion of Silero VAD v6.2.1. The bundled package is pinned to
`FluidInference/silero-vad-coreml` commit
`b419383c55c110e2c9271fa6ee0ea83d03c70d96`; its model card declares MIT and
identifies the Silero Team as the original developer. The upstream license is:

```text
MIT License

Copyright (c) 2020-present Silero Team

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
