# OBSBOT device adapter contract

SOMA separates camera perception from product-specific physical control. A
new UVC camera can therefore provide video, audio, local vision, memory, and
conversation before its gimbal transport is supported.

`soma-obsbot-probe` and `soma-native-track` emit the same versioned
`SOMA_OBSBOT_CAPABILITY` line. The launcher passes that exact line to the
runtime as `SOMA_OBSBOT_CAPABILITY_CONTRACT`; it does not infer hardware from
the camera display name.

The boundary has one direction:

1. L0, L1, L2, settings, and MCP issue semantic requests.
2. `OBSBOTDeviceContract` advertises only connected-device capabilities.
3. `OBSBOTDeviceAdapter` translates supported requests to product SDK calls.
4. The native bridge serializes device ownership, restores temporary state,
   and reports the result.

No cognitive or UI layer owns product IDs, SDK mode numbers, LED state IDs,
or private packet layouts.

## Authority levels

| Contract state | Enabled behaviour |
| --- | --- |
| no valid contract | perception and conversation only |
| `profile=unknown`, `native_bridge=false` | perception and conversation only, with an adapter-required diagnostic |
| `native_bridge=true` without a matching calibration | native observation and LED/audio capabilities only; no external gimbal movement |
| `native_bridge=true` with a matching calibration | L0 tracking, exploration, and higher-layer motion leases within the adapter limits |

The motion gate checks both `native_bridge` and a calibration whose
`deviceIdentifier` matches the adapter identifier. A product name alone never
grants gimbal authority.

## Adding a product adapter

1. Add the SDK product type and its transport implementation in
   `Sources/SOMANativeTracking/OBSBOTDeviceAdapter.cpp`. The contract must
   declare only capabilities verified on hardware.
2. Run the read-only probe. It records the adapter identifier, firmware,
   serial, and supported control surface without changing camera state.
3. Create gimbal and geometry calibrations that carry the same identifier.
   For an unfamiliar optical system, pass its measured nominal wide FOV to
   `scripts/soma-camera-geometry-calibrate.zsh`. The wrapper selects the
   managed Python environment and verifies its OpenCV/SciPy dependencies.
4. Validate LED, native tracking, stop, pose, and external velocity behavior
   on the physical device before enabling motion in the service.

The bridge remains the only owner of vendor SDK commands. L0, L1, and L2 issue
semantic requests; the adapter contracts and calibration decide whether a
specific device can execute them.

## Product modules

| Module | Native tracking | Direct motion | Indicator | Audio extensions |
| --- | --- | --- | --- | --- |
| `Tiny2LiteAdapter` | legacy human-mode transport | Tiny 2 gimbal APIs | physically validated `54` green, `57` blue, `16` yellow; brightness-dimmed host pulse | unavailable unless later validated |
| `Tiny3LiteAdapter` | selected-human portrait transport | Tiny 3 gimbal APIs | firmware status machine with persistent ready baseline; enable-toggled host pulse | validated capture modes, gain, and firmware sound following |
| `UnknownAdapter` | unavailable | unavailable | unavailable | unavailable |

The adapter rejects unsupported commands before a vendor call. An ACK from an
unretained or visually unverified setting is not enough to add that setting to
the contract.

Tiny 3 Lite requires `SYSTEM_READY(3)` to remain present while semantic work
states change. Its verified mapping is normal work `54` for steady green,
tracking work `57` for steady blue, and target-lost `16` for steady yellow.
The native indicator session establishes `3 + 54` at startup and restores that
baseline whenever a temporary presentation is cleared or the bridge exits.
Direct RGB is not part of the contract.

`indicator_pulse_transport` is a device capability rather than a UI policy.
Tiny 2 Lite retains its selected firmware state while brightness is temporarily
set to zero. Tiny 3 Lite instead uses the validated LED-enable transition.
The bridge never substitutes one transport for another when a camera changes.
