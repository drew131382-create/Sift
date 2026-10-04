#!/usr/bin/env python3
"""Developer-only, pinned model preparation. Sift never downloads at runtime.

Default: local fine-tuned Qwen3-0.6B. Baselines remain outside the app bundle.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import urllib.request

PROFILES = {
    "sift-qwen-finetuned": {
        "model": "local/Sift-Qwen3-0.6B-QLoRA",
        "revision": "7252e5c48ad95c76ed8900027d4df16f49a588ef966d1cef654b6af6db1e5a5a",
        "license": "Apache-2.0",
        "licenseDestination": "Qwen3-Apache-2.0.txt",
        "localOnly": True,
        "files": {"config.json", "model.safetensors", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "merges.txt", "vocab.json", "LICENSE", "MODEL_CARD.md", "README.md", "training-provenance.json"},
    },
    "lfm2.5": {
        "model": "mlx-community/LFM2.5-1.2B-Instruct-4bit",
        "revision": "dee2f8a2786e6648bb644a7ca40652842490034b",
        "license": "LFM Open License 1.0",
        "licenseModel": "LiquidAI/LFM2.5-1.2B-Instruct",
        "licenseRevision": "0f604ada3f766f9f257460c4c9f0b5d6f69d431b",
        "licenseDestination": "LFM2.5-Open-License-1.0.txt",
        "files": {"config.json", "model.safetensors", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja", "generation_config.json", "special_tokens_map.json", "LICENSE"},
    },
    "qwen0.6": {
        "model": "Qwen/Qwen3-0.6B-MLX-4bit",
        "revision": "173234aa840d113125e9f2271100ddbaf16c9620",
        "license": "Apache-2.0",
        "licenseDestination": "Qwen3-Apache-2.0.txt",
        "files": {"config.json", "model.safetensors", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "merges.txt", "vocab.json", "LICENSE"},
    },
}
DEFAULT_ROOT = Path(__file__).resolve().parents[1] / "Sift" / "Resources" / "LocalModel"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_local(root, profile):
    manifest = json.loads((root / "manifest.json").read_text())
    assert manifest["model"] == profile["model"] and manifest["revision"] == profile["revision"]
    assert {entry["name"] for entry in manifest["files"]} == profile["files"]
    for entry in manifest["files"]:
        assert Path(entry["name"]).name == entry["name"]
        target = root / entry["name"]
        assert target.stat().st_size == entry["bytes"], f"Wrong size: {entry['name']}"
        assert sha256(target) == entry["sha256"], f"Wrong checksum: {entry['name']}"
    if profile.get("localOnly"):
        assert sha256(root / "model.safetensors") == profile["revision"], "Weights do not match pinned fine-tuned revision"
    print(f"{profile['model']} verified locally; no network used.", flush=True)


def matches_metadata(path, entry):
    if not path.is_file() or path.stat().st_size != entry["size"]:
        return False
    expected = (entry.get("lfs") or {}).get("sha256")
    if expected:
        return sha256(path) == expected
    if entry.get("blobId"):
        content = path.read_bytes()
        return hashlib.sha1(f"blob {len(content)}\0".encode() + content).hexdigest() == entry["blobId"]
    return False


def metadata(model, revision):
    url = f"https://huggingface.co/api/models/{model}/revision/{revision}?blobs=true"
    data = json.load(urllib.request.urlopen(url, timeout=60))
    assert data["sha"] == revision
    return {entry["rfilename"]: entry for entry in data["siblings"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--profile", choices=PROFILES, default="sift-qwen-finetuned")
    parser.add_argument("--output", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--source", type=Path, help="Verified local fine-tuned artifact; never downloaded")
    args = parser.parse_args()
    profile, root = PROFILES[args.profile], args.output.resolve()
    if args.profile != "sift-qwen-finetuned":
        assert root != DEFAULT_ROOT, "Baseline and experimental weights must stay outside the application bundle"
    if args.verify_only:
        verify_local(root, profile)
        return
    if profile.get("localOnly"):
        if args.source is None:
            parser.error("Use --source /path/to/candidate-model-v2 to prepare pinned local weights, or --verify-only to check existing resources. No model is downloaded.")
        source = args.source.resolve()
        assert source != root, "Source must be separate from the application resources"
        verify_local(source, profile)
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".model-preparation-", dir=root.parent) as scratch:
            staged = Path(scratch)
            for name in profile["files"] | {"manifest.json"}:
                shutil.copy2(source / name, staged / name)
            verify_local(staged, profile)
            # Keep the immutable experiment artifact separate from its deployment copy.
            provenance_path = staged / "training-provenance.json"
            provenance = json.loads(provenance_path.read_text())
            provenance["deploymentAtTrainingCompletion"] = {
                "deployedToApplication": provenance.pop("deployedToApplication", False),
                "installedOnIPhone": provenance.pop("installedOnIPhone", False),
            }
            provenance["bundledInSift"] = True
            provenance["deploymentDecision"] = "User selected the measured improvement over the original model; independent acceptance remains pending."
            provenance_path.write_text(json.dumps(provenance, ensure_ascii=False, indent=2) + "\n")
            card_path = staged / "MODEL_CARD.md"
            card = card_path.read_text().replace("；没有部署到软件或安装到 iPhone。", "。训练结束时尚未部署；2026-10-04 已按用户要求纳入 Sift 应用资源，真机安装状态见项目部署记录。")
            card_path.write_text(card)
            manifest = json.loads((staged / "manifest.json").read_text())
            manifest["license"] = profile["license"]
            for entry in manifest["files"]:
                target = staged / entry["name"]
                entry.update(bytes=target.stat().st_size, sha256=sha256(target))
            (staged / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
            verify_local(staged, profile)
            old = json.loads((root / "manifest.json").read_text()) if (root / "manifest.json").exists() else {"files": []}
            for name in sorted(profile["files"]):
                (staged / name).replace(root / name)
            for entry in old["files"]:
                name = entry["name"]
                assert Path(name).name == name
                if name not in profile["files"]:
                    (root / name).unlink(missing_ok=True)
            (staged / "manifest.json").replace(root / "manifest.json")
        if root == DEFAULT_ROOT:
            shutil.copy2(root / "LICENSE", root.parent / "Licenses" / profile["licenseDestination"])
        verify_local(root, profile)
        print("Pinned fine-tuned model ready for bundling.", flush=True)
        return
    assert args.source is None, "--source is for local fine-tuned weights only"
    root.mkdir(parents=True, exist_ok=True)
    entries = metadata(profile["model"], profile["revision"])
    license_model = profile.get("licenseModel", profile["model"])
    license_revision = profile.get("licenseRevision", profile["revision"])
    if license_model != profile["model"]:
        entries["LICENSE"] = metadata(license_model, license_revision)["LICENSE"]
    assert profile["files"].issubset(entries)
    manifest = {"model": profile["model"], "revision": profile["revision"], "license": profile["license"], "files": []}
    if license_model != profile["model"]:
        manifest["licenseSource"] = {"model": license_model, "revision": license_revision}
    # Stage and check every file before touching the installed bundle.
    with tempfile.TemporaryDirectory(prefix=".model-preparation-", dir=root.parent) as scratch:
        staged = Path(scratch)
        for name in sorted(profile["files"]):
            entry, target = entries[name], staged / name
            if matches_metadata(root / name, entry):
                shutil.copy2(root / name, target)
            else:
                model = license_model if name == "LICENSE" else profile["model"]
                revision = license_revision if name == "LICENSE" else profile["revision"]
                request = urllib.request.Request(f"https://huggingface.co/{model}/resolve/{revision}/{name}")
                print(f"Downloading {name} ({entry['size']} bytes)", flush=True)
                with urllib.request.urlopen(request, timeout=180) as response, target.open("wb") as output:
                    while chunk := response.read(4 * 1024 * 1024):
                        output.write(chunk)
            assert matches_metadata(target, entry), f"Wrong size or checksum: {name}"
            manifest["files"].append({"name": name, "bytes": target.stat().st_size, "sha256": sha256(target)})
        # Only remove files owned by the prior manifest; preserve unrelated files.
        old = json.loads((root / "manifest.json").read_text()) if (root / "manifest.json").exists() else {"files": []}
        for name in sorted(profile["files"]):
            (staged / name).replace(root / name)
        for entry in old["files"]:
            name = entry["name"]
            assert Path(name).name == name
            if name not in profile["files"]:
                (root / name).unlink(missing_ok=True)
        if root == DEFAULT_ROOT:
            shutil.copy2(root / "LICENSE", root.parent / "Licenses" / profile["licenseDestination"])
        staged_manifest = staged / "manifest.json"
        staged_manifest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        staged_manifest.replace(root / "manifest.json")
    verify_local(root, profile)
    print("Pinned model ready for bundling.", flush=True)


if __name__ == "__main__":
    main()
