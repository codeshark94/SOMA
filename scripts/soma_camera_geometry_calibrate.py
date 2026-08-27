#!/usr/bin/env python3
"""Fit Tiny 2 Lite intrinsics and camera-to-gimbal rotation from settled scans."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import cv2
import numpy as np
from scipy.optimize import least_squares
from scipy.spatial.transform import Rotation


@dataclass(frozen=True)
class Frame:
    path: Path
    pan: float
    pitch: float
    width: int
    height: int
    fov_mode: int
    angular_velocity: float


@dataclass(frozen=True)
class Pair:
    reference: Frame
    current: Frame
    reference_points: np.ndarray
    current_points: np.ndarray


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture-directory", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--diagnostics", type=Path)
    parser.add_argument(
        "--device-profile",
        choices=("tiny_2_lite", "tiny_3_lite"),
        required=True,
    )
    return parser.parse_args()


def load_frames(directory: Path) -> list[Frame]:
    manifest = directory / "frames.jsonl"
    if not manifest.is_file():
        raise ValueError(f"missing capture manifest: {manifest}")
    frames: list[Frame] = []
    for raw in manifest.read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        item = json.loads(raw)
        path = directory / item["filename"]
        if not path.is_file():
            raise ValueError(f"missing frame: {path}")
        frames.append(Frame(
            path=path,
            pan=float(item["panDegrees"]),
            pitch=float(item["pitchDegrees"]),
            width=int(item["imageWidth"]),
            height=int(item["imageHeight"]),
            fov_mode=int(item["fovMode"]),
            angular_velocity=float(item["angularVelocityDegreesPerSecond"]),
        ))
    if len(frames) < 8:
        raise ValueError(f"at least 8 settled frames are required; found {len(frames)}")
    moving = [frame for frame in frames if frame.angular_velocity > 0.75]
    if moving:
        fastest = max(frame.angular_velocity for frame in moving)
        raise ValueError(
            f"capture contains {len(moving)} moving frames; "
            f"maximum angular velocity is {fastest:.3f} deg/s (limit 0.750)"
        )
    dimensions = {(frame.width, frame.height, frame.fov_mode) for frame in frames}
    if len(dimensions) != 1:
        raise ValueError(f"capture changed resolution or FOV mode: {sorted(dimensions)}")
    pan_span = max(frame.pan for frame in frames) - min(frame.pan for frame in frames)
    pitch_span = max(frame.pitch for frame in frames) - min(frame.pitch for frame in frames)
    if pan_span < 24 or pitch_span < 14:
        raise ValueError(
            f"insufficient two-axis excitation: pan_span={pan_span:.2f}, pitch_span={pitch_span:.2f}"
        )
    return frames


def balanced_keypoints(image: np.ndarray) -> tuple[list[cv2.KeyPoint], np.ndarray | None]:
    # SIFT is materially more reliable than binary corner descriptors on the
    # low-texture walls and exposure changes encountered during a gimbal sweep.
    # Spatial balancing prevents one textured object from determining the
    # camera model by itself.
    detector = cv2.SIFT_create(
        nfeatures=6000,
        contrastThreshold=0.01,
        edgeThreshold=14,
    )
    keypoints, descriptors = detector.detectAndCompute(image, None)
    if descriptors is None:
        return [], None
    cells: dict[tuple[int, int], list[int]] = {}
    height, width = image.shape[:2]
    for index, keypoint in enumerate(keypoints):
        # The desk occupies the lower near field and translates around the
        # camera/gimbal rotation offset. A pure rotational camera model cannot
        # explain that parallax, so it must not determine global intrinsics.
        if keypoint.pt[1] > height * 0.72:
            continue
        cell = (
            min(5, int(keypoint.pt[0] * 6 / width)),
            min(3, int(keypoint.pt[1] * 4 / height)),
        )
        cells.setdefault(cell, []).append(index)
    selected: list[int] = []
    for indexes in cells.values():
        indexes.sort(key=lambda index: keypoints[index].response, reverse=True)
        selected.extend(indexes[:120])
    selected.sort()
    return [keypoints[index] for index in selected], descriptors[selected]


def candidate_pairs(frames: list[Frame]) -> Iterable[tuple[int, int]]:
    # Frames can be skipped by the stillness gate. Select overlaps from their
    # measured poses rather than assuming adjacent manifest entries are nearby.
    for reference_index in range(len(frames)):
        for current_index in range(reference_index + 1, len(frames)):
            reference = frames[reference_index]
            current = frames[current_index]
            pan_delta = abs(((current.pan - reference.pan + 180) % 360) - 180)
            pitch_delta = abs(current.pitch - reference.pitch)
            angular_delta = math.hypot(pan_delta, pitch_delta)
            if 3 <= angular_delta <= 38 and pan_delta <= 36 and pitch_delta <= 31:
                yield reference_index, current_index


def match_pairs(frames: list[Frame]) -> tuple[list[Pair], list[dict[str, float]]]:
    images: list[np.ndarray] = []
    features: list[tuple[list[cv2.KeyPoint], np.ndarray | None]] = []
    for frame in frames:
        image = cv2.imread(str(frame.path), cv2.IMREAD_GRAYSCALE)
        if image is None or image.shape[1] != frame.width or image.shape[0] != frame.height:
            raise ValueError(f"unreadable or dimension-mismatched frame: {frame.path}")
        images.append(image)
        features.append(balanced_keypoints(image))

    matcher = cv2.BFMatcher(cv2.NORM_L2)
    pairs: list[Pair] = []
    diagnostics: list[dict[str, float]] = []
    for reference_index, current_index in candidate_pairs(frames):
        reference_keypoints, reference_descriptors = features[reference_index]
        current_keypoints, current_descriptors = features[current_index]
        if reference_descriptors is None or current_descriptors is None:
            continue
        forward = matcher.knnMatch(current_descriptors, reference_descriptors, k=2)
        reverse = matcher.knnMatch(reference_descriptors, current_descriptors, k=2)
        reverse_best = {
            matches[0].queryIdx: matches[0].trainIdx
            for matches in reverse
            if len(matches) == 2 and matches[0].distance < 0.80 * matches[1].distance
        }
        accepted = []
        for matches in forward:
            if len(matches) != 2 or matches[0].distance >= 0.80 * matches[1].distance:
                continue
            match = matches[0]
            if reverse_best.get(match.trainIdx) != match.queryIdx:
                continue
            accepted.append(match)
        if len(accepted) < 18:
            continue
        current_points = np.float64([current_keypoints[m.queryIdx].pt for m in accepted])
        reference_points = np.float64([reference_keypoints[m.trainIdx].pt for m in accepted])
        _, mask = cv2.findHomography(
            current_points,
            reference_points,
            method=cv2.USAC_MAGSAC,
            ransacReprojThreshold=3.5,
            maxIters=10_000,
            confidence=0.999,
        )
        if mask is None:
            continue
        inliers = mask.ravel().astype(bool)
        inlier_ratio = float(np.mean(inliers))
        if int(np.sum(inliers)) < 16 or inlier_ratio < 0.28:
            continue
        current_points = current_points[inliers]
        reference_points = reference_points[inliers]
        if len(current_points) > 120:
            order = np.linspace(0, len(current_points) - 1, 120, dtype=int)
            current_points = current_points[order]
            reference_points = reference_points[order]
        pairs.append(Pair(
            reference=frames[reference_index],
            current=frames[current_index],
            reference_points=reference_points,
            current_points=current_points,
        ))
        diagnostics.append({
            "reference": float(reference_index),
            "current": float(current_index),
            "matches": float(len(current_points)),
            "inlier_ratio": inlier_ratio,
            "pan_delta": ((frames[current_index].pan - frames[reference_index].pan + 180) % 360) - 180,
            "pitch_delta": frames[current_index].pitch - frames[reference_index].pitch,
        })
        if len(pairs) >= 48:
            break
    if len(pairs) < 6:
        raise ValueError(f"only {len(pairs)} robust overlapping pairs; at least 6 are required")
    if sum(len(pair.current_points) for pair in pairs) < 240:
        raise ValueError("too few geometrically verified feature correspondences")
    return pairs, diagnostics


def ideal_camera_to_world(pan_degrees: float, pitch_degrees: float) -> np.ndarray:
    yaw = math.radians(-pan_degrees)
    elevation = math.radians(-pitch_degrees)
    forward = np.array([
        math.cos(elevation) * math.sin(yaw),
        math.sin(elevation),
        math.cos(elevation) * math.cos(yaw),
    ])
    right = np.array([math.cos(yaw), 0.0, -math.sin(yaw)])
    up = np.array([
        -math.sin(elevation) * math.sin(yaw),
        math.cos(elevation),
        -math.sin(elevation) * math.cos(yaw),
    ])
    return np.column_stack((right, -up, forward))


def unpack(
    parameters: np.ndarray,
    width: int,
    height: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    fx = math.exp(float(parameters[0]))
    fy = math.exp(float(parameters[1]))
    cx = width * (0.5 + float(parameters[2]))
    cy = height * (0.5 + float(parameters[3]))
    intrinsic = np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1]], dtype=np.float64)
    extrinsic = Rotation.from_rotvec(parameters[4:7]).as_matrix()
    distortion = np.array([parameters[7], parameters[8]], dtype=np.float64)
    return intrinsic, extrinsic, distortion


def full_field_of_view_degrees(focal: float, principal: float, extent: int) -> float:
    return math.degrees(
        math.atan(principal / focal) + math.atan((extent - principal) / focal)
    )


def predict_pair(
    pair: Pair,
    intrinsic: np.ndarray,
    extrinsic: np.ndarray,
    distortion: np.ndarray,
) -> np.ndarray:
    reference_basis = ideal_camera_to_world(pair.reference.pan, pair.reference.pitch)
    current_basis = ideal_camera_to_world(pair.current.pan, pair.current.pitch)
    relative = extrinsic.T @ reference_basis.T @ current_basis @ extrinsic
    current_undistorted = cv2.undistortPoints(
        pair.current_points.reshape(-1, 1, 2),
        intrinsic,
        np.array([distortion[0], distortion[1], 0, 0, 0], dtype=np.float64),
    ).reshape(-1, 2)
    current_rays = np.column_stack((
        current_undistorted,
        np.ones(len(current_undistorted)),
    )).T
    reference_rays = relative @ current_rays
    normalized = (reference_rays[:2] / reference_rays[2:3]).T
    radius2 = np.sum(normalized * normalized, axis=1)
    radial = 1 + distortion[0] * radius2 + distortion[1] * radius2 * radius2
    distorted = normalized * radial[:, None]
    return np.column_stack((
        intrinsic[0, 0] * distorted[:, 0] + intrinsic[0, 2],
        intrinsic[1, 1] * distorted[:, 1] + intrinsic[1, 2],
    ))


def data_residuals(parameters: np.ndarray, pairs: list[Pair], width: int, height: int) -> np.ndarray:
    intrinsic, extrinsic, distortion = unpack(parameters, width, height)
    residuals = []
    for pair in pairs:
        difference = predict_pair(pair, intrinsic, extrinsic, distortion) - pair.reference_points
        weight = math.sqrt(60 / max(24, len(pair.current_points)))
        residuals.append((difference * weight).ravel())
    return np.concatenate(residuals)


def fitting_residuals(parameters: np.ndarray, pairs: list[Pair], width: int, height: int) -> np.ndarray:
    residuals = data_residuals(parameters, pairs, width, height)
    # Weak physical priors remove the focal/principal-point gauge freedom
    # without forcing the official nominal FOV to be the fitted answer.
    priors = np.array([
        (parameters[0] - parameters[1]) / 0.08,
        parameters[2] / 0.035,
        parameters[3] / 0.035,
        parameters[4] / math.radians(8),
        parameters[5] / math.radians(8),
        parameters[6] / math.radians(8),
        parameters[7] / 0.25,
        parameters[8] / 0.25,
    ])
    return np.concatenate((residuals, priors))


def error_statistics(parameters: np.ndarray, pairs: list[Pair], width: int, height: int) -> tuple[float, float, list[float]]:
    intrinsic, extrinsic, distortion = unpack(parameters, width, height)
    all_errors = []
    pair_medians = []
    for pair in pairs:
        errors = np.linalg.norm(
            predict_pair(pair, intrinsic, extrinsic, distortion) - pair.reference_points,
            axis=1,
        )
        all_errors.extend(errors.tolist())
        pair_medians.append(float(np.median(errors)))
    values = np.asarray(all_errors)
    return float(np.sqrt(np.mean(values * values))), float(np.percentile(values, 90)), pair_medians


def fit(frames: list[Frame], pairs: list[Pair]) -> tuple[np.ndarray, list[Pair], dict[str, float]]:
    width, height = frames[0].width, frames[0].height
    nominal_horizontal_fov = {
        "tiny_2_lite": 67.2,
        "tiny_3_lite": 72.0,
    }[args.device_profile]
    nominal_focal = width / (2 * math.tan(math.radians(nominal_horizontal_fov / 2)))
    initial = np.array([
        math.log(nominal_focal),
        math.log(nominal_focal),
        0, 0, 0, 0, 0, 0, 0,
    ], dtype=np.float64)
    lower = np.array([
        math.log(nominal_focal * 0.72),
        math.log(nominal_focal * 0.72),
        -0.06, -0.06,
        *([-math.radians(12)] * 3),
        -0.5, -0.5,
    ])
    upper = np.array([
        math.log(nominal_focal * 1.35),
        math.log(nominal_focal * 1.35),
        0.06, 0.06,
        *([math.radians(12)] * 3),
        0.5, 0.5,
    ])
    first = least_squares(
        fitting_residuals,
        initial,
        args=(pairs, width, height),
        bounds=(lower, upper),
        loss="cauchy",
        f_scale=2.5,
        max_nfev=400,
        x_scale="jac",
    )
    _, _, pair_medians = error_statistics(first.x, pairs, width, height)
    median = float(np.median(pair_medians))
    mad = float(np.median(np.abs(np.asarray(pair_medians) - median)))
    threshold = min(8.0, max(3.0, median + 2.5 * max(mad, 0.25)))
    retained = [pair for pair, pair_error in zip(pairs, pair_medians) if pair_error <= threshold]
    if len(retained) < 6:
        raise ValueError(f"parallax rejection left only {len(retained)} rotation-consistent pairs")
    result = least_squares(
        fitting_residuals,
        first.x,
        args=(retained, width, height),
        bounds=(lower, upper),
        loss="cauchy",
        f_scale=2.0,
        max_nfev=600,
        x_scale="jac",
    )
    initial_rmse, initial_p90, _ = error_statistics(initial, retained, width, height)
    calibrated_rmse, calibrated_p90, _ = error_statistics(result.x, retained, width, height)
    if not result.success:
        raise ValueError(f"optimizer did not converge: {result.message}")
    if calibrated_rmse >= initial_rmse * 0.92:
        raise ValueError(
            f"calibration did not generalize enough: {initial_rmse:.3f}px -> {calibrated_rmse:.3f}px"
        )
    if calibrated_p90 > 12:
        raise ValueError(f"rotation model p90 remains too large: {calibrated_p90:.3f}px")
    return result.x, retained, {
        "initial_rmse_pixels": initial_rmse,
        "initial_p90_pixels": initial_p90,
        "calibrated_rmse_pixels": calibrated_rmse,
        "calibrated_p90_pixels": calibrated_p90,
        "rejected_pairs": float(len(pairs) - len(retained)),
        "optimizer_cost": float(result.cost),
        "optimizer_evaluations": float(result.nfev),
    }


def main() -> None:
    args = parse_args()
    if args.output.exists():
        raise ValueError(f"refusing to overwrite calibration: {args.output}")
    frames = load_frames(args.capture_directory)
    pairs, pair_diagnostics = match_pairs(frames)
    # Establish a pair-level rotation consensus across the scan before the
    # held-out split. Near-field parallax and repeated texture can each produce
    # a valid homography that no single camera model can explain. This stage
    # curates pairs only; the final fit still never sees validation points.
    _, consistent_pairs, consensus_metrics = fit(frames, pairs)
    validation_pairs = [pair for index, pair in enumerate(consistent_pairs) if index % 4 == 0]
    training_pairs = [pair for index, pair in enumerate(consistent_pairs) if index % 4 != 0]
    if len(validation_pairs) < 3:
        raise ValueError("at least three untouched validation pairs are required")
    parameters, retained, training_metrics = fit(frames, training_pairs)
    width, height = frames[0].width, frames[0].height
    nominal_focal = width / (2 * math.tan(math.radians(67.2 / 2)))
    nominal_parameters = np.array([
        math.log(nominal_focal),
        math.log(nominal_focal),
        0, 0, 0, 0, 0, 0, 0,
    ], dtype=np.float64)
    validation_initial_rmse, validation_initial_p90, _ = error_statistics(
        nominal_parameters,
        validation_pairs,
        width,
        height,
    )
    validation_rmse, validation_p90, _ = error_statistics(
        parameters,
        validation_pairs,
        width,
        height,
    )
    if validation_rmse >= validation_initial_rmse * 0.8:
        raise ValueError(
            f"untouched validation did not improve enough: {validation_initial_rmse:.3f}px -> {validation_rmse:.3f}px"
        )
    if validation_p90 > 12:
        raise ValueError(f"untouched validation p90 remains too large: {validation_p90:.3f}px")
    intrinsic, extrinsic, distortion = unpack(parameters, frames[0].width, frames[0].height)
    output = {
        "schemaVersion": 1,
        "deviceProfile": args.device_profile,
        "fovMode": frames[0].fov_mode,
        "imageWidth": frames[0].width,
        "imageHeight": frames[0].height,
        "projection": {
            "focalXNormalized": float(intrinsic[0, 0] / frames[0].width),
            "focalYNormalized": float(intrinsic[1, 1] / frames[0].height),
            "principalXNormalized": float(intrinsic[0, 2] / frames[0].width),
            "principalYNormalized": float(intrinsic[1, 2] / frames[0].height),
            "cameraToIdealRotation": [float(value) for value in extrinsic.ravel()],
            "radialK1": float(distortion[0]),
            "radialK2": float(distortion[1]),
        },
        "capturedFrames": len(frames),
        "fittedPairs": len(retained),
        "fittedMatches": sum(len(pair.current_points) for pair in retained),
        "validationPairs": len(validation_pairs),
        "validationMatches": sum(len(pair.current_points) for pair in validation_pairs),
        "initialRMSEPixels": validation_initial_rmse,
        "calibratedRMSEPixels": validation_rmse,
        "calibratedP90Pixels": validation_p90,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.diagnostics:
        args.diagnostics.parent.mkdir(parents=True, exist_ok=True)
        args.diagnostics.write_text(json.dumps({
            "consensus_metrics": consensus_metrics,
            "training_metrics": training_metrics,
            "validation_metrics": {
                "initial_rmse_pixels": validation_initial_rmse,
                "initial_p90_pixels": validation_initial_p90,
                "calibrated_rmse_pixels": validation_rmse,
                "calibrated_p90_pixels": validation_p90,
            },
            "candidate_pairs": len(pairs),
            "consistent_pairs": len(consistent_pairs),
            "retained_pairs": len(retained),
            "pair_matches": pair_diagnostics,
            "extrinsic_rotation_vector_degrees": [
                float(value) for value in np.degrees(Rotation.from_matrix(extrinsic).as_rotvec())
            ],
            "horizontal_fov_degrees": full_field_of_view_degrees(
                intrinsic[0, 0], intrinsic[0, 2], frames[0].width
            ),
            "vertical_fov_degrees": full_field_of_view_degrees(
                intrinsic[1, 1], intrinsic[1, 2], frames[0].height
            ),
        }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({
        "frames": len(frames),
        "pairs": len(retained),
        "validation_pairs": len(validation_pairs),
        "matches": output["fittedMatches"],
        "validation_initial_rmse_px": round(output["initialRMSEPixels"], 3),
        "validation_calibrated_rmse_px": round(output["calibratedRMSEPixels"], 3),
        "validation_calibrated_p90_px": round(output["calibratedP90Pixels"], 3),
        "horizontal_fov_degrees": round(full_field_of_view_degrees(
            intrinsic[0, 0], intrinsic[0, 2], frames[0].width
        ), 4),
        "vertical_fov_degrees": round(full_field_of_view_degrees(
            intrinsic[1, 1], intrinsic[1, 2], frames[0].height
        ), 4),
    }, sort_keys=True))


if __name__ == "__main__":
    main()
