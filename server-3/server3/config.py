from __future__ import annotations

import base64
import binascii
import hashlib
import json
from dataclasses import dataclass
from typing import Any, Iterable

CONFIG_VERSION_DEFAULT = "0.002"
BUNDLE_FORMAT = "openpcc.ohttp.keybundle.v0.002"
PUBLIC_KEY_FORMAT = "sha256-seed"


class ConfigError(ValueError):
    pass


@dataclass(frozen=True)
class Features:
    ohttp: bool
    real_attestation: bool


@dataclass(frozen=True)
class OHTTPSeed:
    key_id: str
    seed_hex: str
    active_from: str
    active_until: str


@dataclass(frozen=True)
class AttestationConfig:
    policy_id: str
    allowed: dict[str, Any]
    verifier_hints: dict[str, Any]


@dataclass(frozen=True)
class ServerConfig:
    version: str
    features: Features
    relay_urls: list[str]
    gateway_url: str
    router_url: str
    ohttp_seeds: list[OHTTPSeed]
    attestation: AttestationConfig | None


def load_config(path: str | None, json_value: str | None) -> dict[str, Any]:
    if json_value:
        try:
            data = json.loads(json_value)
        except json.JSONDecodeError as exc:
            raise ConfigError(f"Invalid SERVER3_CONFIG_JSON: {exc}") from exc
    else:
        if not path:
            raise ConfigError(
                "SERVER3_CONFIG_PATH is required when SERVER3_CONFIG_JSON is empty."
            )
        try:
            with open(path, "r", encoding="utf-8") as handle:
                data = json.load(handle)
        except FileNotFoundError:
            raise ConfigError(f"Config file not found: {path}") from None
        except json.JSONDecodeError as exc:
            raise ConfigError(f"Invalid JSON in {path}: {exc}") from exc

    if not isinstance(data, dict):
        raise ConfigError("Config root must be a JSON object.")
    return data


def parse_config(raw: dict[str, Any]) -> ServerConfig:
    version = _get_str(raw, "version") or CONFIG_VERSION_DEFAULT
    features = _parse_features(raw.get("features"))

    relay_urls: list[str] = []
    gateway_url = ""
    router_url = ""
    ohttp_seeds: list[OHTTPSeed] = []
    if features.ohttp:
        relay_urls = _get_str_list(raw, "relay_urls", required=True)
        gateway_url = _get_str(raw, "gateway_url", required=True)
        router_url = _get_str(raw, "router_url", required=True)
        ohttp_seeds = _parse_ohttp_seeds(raw.get("ohttp_seeds"))

    attestation: AttestationConfig | None = None
    if features.real_attestation:
        attestation = _parse_attestation(raw.get("attestation"))

    return ServerConfig(
        version=version,
        features=features,
        relay_urls=relay_urls,
        gateway_url=gateway_url,
        router_url=router_url,
        ohttp_seeds=ohttp_seeds,
        attestation=attestation,
    )


def build_api_payload(config: ServerConfig) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "version": config.version,
        "features": {
            "ohttp": config.features.ohttp,
            "real_attestation": config.features.real_attestation,
        },
        "relay_urls": [],
        "gateway_url": "",
        "router_url": "",
        "ohttp_key_configs_bundle": "",
        "ohttp_key_rotation_periods": [],
        "attestation": {},
    }

    if config.features.ohttp:
        payload["relay_urls"] = config.relay_urls
        payload["gateway_url"] = config.gateway_url
        payload["router_url"] = config.router_url
        payload["ohttp_key_configs_bundle"] = build_ohttp_bundle(config.ohttp_seeds)
        payload["ohttp_key_rotation_periods"] = build_rotation_periods(config.ohttp_seeds)

    if config.features.real_attestation:
        if config.attestation is None:
            raise ConfigError("attestation config is required when real_attestation is true")
        attestation_payload: dict[str, Any] = {
            "policy_id": config.attestation.policy_id,
        }
        if config.attestation.allowed:
            attestation_payload["allowed"] = config.attestation.allowed
        if config.attestation.verifier_hints:
            attestation_payload["verifier_hints"] = config.attestation.verifier_hints
        payload["attestation"] = attestation_payload

    return payload


def build_rotation_periods(seeds: Iterable[OHTTPSeed]) -> list[dict[str, str]]:
    periods: list[dict[str, str]] = []
    for seed in seeds:
        periods.append(
            {
                "key_id": seed.key_id,
                "active_from": seed.active_from,
                "active_until": seed.active_until,
            }
        )
    return periods


def build_ohttp_bundle(seeds: Iterable[OHTTPSeed]) -> str:
    keys: list[dict[str, str]] = []
    for seed in seeds:
        public_key = derive_public_key_bytes(seed.seed_hex, seed.key_id)
        keys.append(
            {
                "key_id": seed.key_id,
                "public_key_b64": base64.b64encode(public_key).decode("ascii"),
                "public_key_format": PUBLIC_KEY_FORMAT,
            }
        )
    bundle = {"format": BUNDLE_FORMAT, "keys": keys}
    bundle_json = json.dumps(bundle, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return base64.b64encode(bundle_json).decode("ascii")


def derive_public_key_bytes(seed_hex: str, key_id: str) -> bytes:
    seed_bytes = _decode_hex(seed_hex, "ohttp_seeds.seed_hex")
    key_id_bytes = _parse_key_id_bytes(key_id)
    digest = hashlib.sha256(seed_bytes + key_id_bytes).digest()
    return digest


def _parse_features(raw: Any) -> Features:
    if raw is None:
        return Features(ohttp=True, real_attestation=True)
    if not isinstance(raw, dict):
        raise ConfigError("features must be an object")
    ohttp = raw.get("ohttp")
    real_attestation = raw.get("real_attestation")
    if not isinstance(ohttp, bool):
        raise ConfigError("features.ohttp must be a boolean")
    if not isinstance(real_attestation, bool):
        raise ConfigError("features.real_attestation must be a boolean")
    return Features(ohttp=ohttp, real_attestation=real_attestation)


def _parse_ohttp_seeds(raw: Any) -> list[OHTTPSeed]:
    if not isinstance(raw, list) or not raw:
        raise ConfigError("ohttp_seeds must be a non-empty list")
    seeds: list[OHTTPSeed] = []
    seen_ids: set[str] = set()
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            raise ConfigError(f"ohttp_seeds[{index}] must be an object")
        key_id = _get_str(item, "key_id", required=True)
        seed_hex = _get_str(item, "seed_hex", required=True)
        active_from = _get_str(item, "active_from", required=True)
        active_until = _get_str(item, "active_until", required=True)
        _decode_hex(seed_hex, f"ohttp_seeds[{index}].seed_hex")
        if key_id in seen_ids:
            raise ConfigError(f"ohttp_seeds[{index}].key_id is duplicated: {key_id}")
        seen_ids.add(key_id)
        seeds.append(
            OHTTPSeed(
                key_id=key_id,
                seed_hex=seed_hex,
                active_from=active_from,
                active_until=active_until,
            )
        )
    return seeds


def _parse_attestation(raw: Any) -> AttestationConfig:
    if not isinstance(raw, dict):
        raise ConfigError("attestation must be an object")
    policy_id = _get_str(raw, "policy_id", required=True)
    allowed = raw.get("allowed")
    allowed_from_prefix = _extract_allowed_prefixed(raw)
    if allowed is not None and allowed_from_prefix:
        raise ConfigError("attestation.allowed and attestation.allowed_* cannot be mixed")
    if allowed is None:
        allowed = allowed_from_prefix
    if not isinstance(allowed, dict):
        raise ConfigError("attestation.allowed must be an object")
    verifier_hints = raw.get("verifier_hints", {})
    if not isinstance(verifier_hints, dict):
        raise ConfigError("attestation.verifier_hints must be an object")
    return AttestationConfig(
        policy_id=policy_id,
        allowed=allowed,
        verifier_hints=verifier_hints,
    )


def _extract_allowed_prefixed(raw: dict[str, Any]) -> dict[str, Any]:
    allowed: dict[str, Any] = {}
    for key, value in raw.items():
        if key.startswith("allowed_"):
            allowed[key[len("allowed_") :]] = value
    return allowed


def _parse_key_id_bytes(key_id: str) -> bytes:
    if not key_id:
        raise ConfigError("ohttp_seeds.key_id must be a non-empty string")
    if _looks_like_hex(key_id):
        try:
            return bytes.fromhex(key_id)
        except ValueError:
            return key_id.encode("utf-8")
    return key_id.encode("utf-8")


def _decode_hex(value: str, label: str) -> bytes:
    if not _looks_like_hex(value):
        raise ConfigError(f"{label} must be a hex string")
    try:
        return binascii.unhexlify(value)
    except (binascii.Error, ValueError) as exc:
        raise ConfigError(f"{label} must be valid hex") from exc


def _looks_like_hex(value: str) -> bool:
    if len(value) % 2 != 0:
        return False
    try:
        int(value, 16)
    except ValueError:
        return False
    return True


def _get_str(source: dict[str, Any], key: str, required: bool = False) -> str:
    value = source.get(key)
    if value is None:
        if required:
            raise ConfigError(f"{key} is required")
        return ""
    if not isinstance(value, str):
        raise ConfigError(f"{key} must be a string")
    value = value.strip()
    if required and not value:
        raise ConfigError(f"{key} must be a non-empty string")
    return value


def _get_str_list(source: dict[str, Any], key: str, required: bool = False) -> list[str]:
    value = source.get(key)
    if value is None:
        if required:
            raise ConfigError(f"{key} is required")
        return []
    if not isinstance(value, list):
        raise ConfigError(f"{key} must be a list")
    items: list[str] = []
    for index, item in enumerate(value):
        if not isinstance(item, str):
            raise ConfigError(f"{key}[{index}] must be a string")
        item = item.strip()
        if not item:
            raise ConfigError(f"{key}[{index}] must be a non-empty string")
        items.append(item)
    if required and not items:
        raise ConfigError(f"{key} must be a non-empty list")
    return items
