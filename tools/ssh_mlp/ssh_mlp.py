#!/usr/bin/env python3
import argparse
import concurrent.futures
import hashlib
import json
import logging
import os
import re
import shlex
import shutil
import subprocess
import struct
import sys
import threading
import time
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath


APP_NAME = "ssh_mlp"
META_SUFFIX = ".ssh_mlp_meta.json"
DEFAULT_CONFIG = """# ssh_mlp config
# Remote paths in .mlp files are downloaded through this SSH host alias.
REMOTE_HOST=133757

# Optional remote root for relative paths in .mlp files.
REMOTE_ROOT=

# The app that should open the rewritten local .mlp.
MESHLAB_APP=/Applications/Mesh Compare.app

# Local cache for downloaded mesh files and rewritten .mlp files.
CACHE_DIR=~/Library/Caches/ssh_mlp

# Parallel downloads.
JOBS=6

# Normalize downloaded .ply/.obj meshes into [-1, 1]^3 before opening.
NORMALIZE_MESHES=0
"""


def user_path(path):
    return Path(os.path.expandvars(os.path.expanduser(path)))


def config_path():
    return user_path("~/.config/ssh_mlp/config")


def read_config():
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.write_text(DEFAULT_CONFIG, encoding="utf-8")

    config = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        config[key.strip()] = value.strip().strip('"').strip("'")

    return {
        "remote_host": os.environ.get("SSH_MLP_REMOTE_HOST", config.get("REMOTE_HOST", "133757")),
        "remote_root": os.environ.get("SSH_MLP_REMOTE_ROOT", config.get("REMOTE_ROOT", "")),
        "meshlab_app": os.environ.get("SSH_MLP_MESHLAB_APP", config.get("MESHLAB_APP", "/Applications/Mesh Compare.app")),
        "cache_dir": str(user_path(os.environ.get("SSH_MLP_CACHE_DIR", config.get("CACHE_DIR", "~/Library/Caches/ssh_mlp")))),
        "jobs": int(os.environ.get("SSH_MLP_JOBS", config.get("JOBS", "6"))),
        "normalize_meshes": config_bool(os.environ.get("SSH_MLP_NORMALIZE_MESHES", config.get("NORMALIZE_MESHES", "0"))),
    }


def write_config(config):
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    text = f"""# ssh_mlp config
# Remote paths in .mlp files are downloaded through this SSH host alias.
REMOTE_HOST={config["remote_host"]}

# Optional remote root for relative paths in .mlp files.
REMOTE_ROOT={config["remote_root"]}

# The app that should open the rewritten local .mlp.
MESHLAB_APP={config["meshlab_app"]}

# Local cache for downloaded mesh files and rewritten .mlp files.
CACHE_DIR={config["cache_dir"]}

# Parallel downloads.
JOBS={config["jobs"]}

# Normalize downloaded .ply/.obj meshes into [-1, 1]^3 before opening.
NORMALIZE_MESHES={1 if config.get("normalize_meshes") else 0}
"""
    path.write_text(text, encoding="utf-8")


def config_bool(value):
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def setup_logging(cache_dir):
    log_dir = user_path("~/Library/Logs")
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "ssh_mlp.log"
    logging.basicConfig(
        filename=str(log_file),
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    Path(cache_dir).mkdir(parents=True, exist_ok=True)
    return log_file


def notify(title, message):
    script = (
        "on run argv\n"
        "  display notification (item 2 of argv) with title (item 1 of argv)\n"
        "end run\n"
    )
    subprocess.run(["osascript", "-e", script, title, message], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def configure_ui():
    subprocess.Popen(["open", "-a", "/Applications/ssh_mlp.app"])
    return 0


def stable_key(text):
    return hashlib.sha1(text.encode("utf-8")).hexdigest()[:16]


class ProgressReporter:
    def __init__(self, enabled=False):
        self.enabled = enabled
        self.lock = threading.Lock()

    def add(self, key, label):
        self.emit("item", key=key, label=label, status="pending", detail="", transferred=0, total=0, speed=0)

    def update(self, key, status, detail="", transferred=None, total=None, speed=None):
        payload = {"key": key, "label": key, "status": status, "detail": detail}
        if transferred is not None:
            payload["transferred"] = transferred
        if total is not None:
            payload["total"] = total
        if speed is not None:
            payload["speed"] = speed
        self.emit("item", **payload)

    def set_message(self, message):
        self.emit("message", message=message)

    def complete(self, outputs):
        self.emit("complete", outputs=[str(path) for path in outputs])

    def error(self, message):
        self.emit("error", message=message)

    def emit(self, event, **payload):
        if not self.enabled:
            return
        payload["event"] = event
        with self.lock:
            print(json.dumps(payload, ensure_ascii=False), flush=True)


def safe_host_name(host):
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", host)


def cache_path_for_remote(cache_dir, host, remote_path):
    parts = []
    for part in PurePosixPath(remote_path).parts:
        if part in ("", "/", ".", ".."):
            continue
        parts.append(part)
    if not parts:
        parts = [stable_key(remote_path)]
    return Path(cache_dir) / "files" / safe_host_name(host) / Path(*parts)


def local_path_for(raw, mlp_path):
    expanded = os.path.expanduser(raw)
    path = Path(expanded)
    if path.is_absolute():
        return path
    return (mlp_path.parent / path).resolve()


def relative_for_remote_root(raw, remote_root):
    raw_path = PurePosixPath(raw)
    if not raw_path.is_absolute():
        return str(raw_path)

    root = PurePosixPath(remote_root) if remote_root else None
    if root:
        try:
            return str(raw_path.relative_to(root))
        except ValueError:
            pass
    return str(raw_path).lstrip("/")


def remote_candidates_for(raw, remote_root):
    candidates = []
    if remote_root:
        rel = relative_for_remote_root(raw, remote_root)
        if rel and rel != ".":
            candidates.append(("root+relative", str(PurePosixPath(remote_root) / rel)))
    if PurePosixPath(raw).is_absolute():
        candidates.append(("absolute", str(PurePosixPath(raw))))

    seen = set()
    unique = []
    for label, path in candidates:
        if path not in seen:
            seen.add(path)
            unique.append((label, path))
    return unique


def remote_file_exists(host, remote_path):
    cmd = ["ssh", host, "test -r " + shlex.quote(remote_path)]
    return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def remote_file_size(host, remote_path):
    stat = remote_file_stat(host, remote_path)
    return stat["size"] if stat else None


def remote_file_stat(host, remote_path):
    quoted = shlex.quote(remote_path)
    cmd = ["ssh", host, f"stat -c '%s %Y' -- {quoted}"]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    if proc.returncode != 0:
        return None
    matches = re.findall(r"(?m)(\d+)\s+(\d+)", proc.stdout)
    if not matches:
        return None
    try:
        size, mtime = matches[-1]
        return {"size": int(size), "mtime": int(mtime)}
    except ValueError:
        return None


def cache_meta_path(dest):
    return Path(str(dest) + META_SUFFIX)


def read_cache_meta(dest):
    path = cache_meta_path(dest)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def write_cache_meta(dest, host, remote_path, remote_stat):
    if not remote_stat:
        return
    meta = {
        "host": host,
        "remote_path": remote_path,
        "size": int(remote_stat["size"]),
        "mtime": int(remote_stat["mtime"]),
        "cached_at": int(time.time()),
    }
    cache_meta_path(dest).write_text(json.dumps(meta, sort_keys=True), encoding="utf-8")


def cache_is_fresh(dest, host, remote_path, remote_stat):
    dest = Path(dest)
    if not remote_stat or not dest.exists() or dest.stat().st_size <= 0:
        return False
    if dest.stat().st_size != int(remote_stat["size"]):
        return False
    meta = read_cache_meta(dest)
    if not meta:
        return False
    return (
        meta.get("host") == host
        and meta.get("remote_path") == remote_path
        and int(meta.get("size", -1)) == int(remote_stat["size"])
        and int(meta.get("mtime", -1)) == int(remote_stat["mtime"])
    )


def choose_remote_path(host, raw, mlp_path, remote_root, cache_dir, refresh=False, progress=None):
    local_candidate = local_path_for(raw, mlp_path)
    if local_candidate.exists():
        if progress:
            progress.update(raw, "local", str(local_candidate))
        return None

    candidates = remote_candidates_for(raw, remote_root)
    if not candidates:
        if progress:
            progress.update(raw, "error", "missing locally; no remote candidate")
        raise RuntimeError(f"missing locally and no SSH candidate for {raw}")

    for label, remote_path in candidates:
        dest = cache_path_for_remote(cache_dir, host, remote_path)
        if dest.exists() and dest.stat().st_size > 0 and not refresh:
            if progress:
                progress.update(raw, "cached", f"{label}: {remote_path}")
            return remote_path, None

        if progress:
            progress.update(raw, "checking", f"{label}: {remote_path}")
        remote_stat = remote_file_stat(host, remote_path)
        if remote_stat:
            return remote_path, remote_stat

    if progress:
        progress.update(raw, "error", "not found on local path, root+relative path, or absolute path")
    tried = "; ".join(path for _label, path in candidates)
    raise RuntimeError(f"missing file for {raw}; tried local path and SSH paths: {tried}")


def download_remote_file(host, raw, remote_path, dest, refresh=False, remote_stat=None, progress=None):
    if dest.exists() and dest.stat().st_size > 0 and not refresh:
        size = dest.stat().st_size
        logging.info("cache hit: %s -> %s", remote_path, dest)
        if progress:
            progress.update(raw, "cached", str(dest), transferred=size, total=size, speed=0)
        return dest

    if remote_stat is None:
        remote_stat = remote_file_stat(host, remote_path)

    if refresh and cache_is_fresh(dest, host, remote_path, remote_stat):
        size = dest.stat().st_size
        logging.info("cache fresh: %s -> %s", remote_path, dest)
        if progress:
            progress.update(raw, "cached", f"up to date: {dest}", transferred=size, total=size, speed=0)
        return dest

    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(f"{dest.name}.part.{os.getpid()}.{uuid.uuid4().hex}")
    total = remote_stat["size"] if remote_stat else remote_file_size(host, remote_path)
    cmd = ["ssh", host, "cat -- " + shlex.quote(remote_path)]
    logging.info("download: %s:%s -> %s", host, remote_path, dest)
    if progress:
        progress.update(raw, "downloading", remote_path, transferred=0, total=total or 0, speed=0)

    transferred = 0
    last_emit = time.monotonic()
    last_bytes = 0
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        assert proc.stdout is not None
        with tmp.open("wb") as out:
            while True:
                chunk = proc.stdout.read(1024 * 1024)
                if not chunk:
                    break
                out.write(chunk)
                transferred += len(chunk)
                now = time.monotonic()
                if progress and now - last_emit >= 0.25:
                    speed = (transferred - last_bytes) / max(now - last_emit, 0.001)
                    progress.update(
                        raw,
                        "downloading",
                        remote_path,
                        transferred=transferred,
                        total=total or 0,
                        speed=speed,
                    )
                    last_emit = now
                    last_bytes = transferred
        stderr = proc.stderr.read() if proc.stderr else b""
        returncode = proc.wait()
    except Exception:
        proc.kill()
        proc.wait()
        tmp.unlink(missing_ok=True)
        raise

    if returncode != 0:
        tmp.unlink(missing_ok=True)
        err = stderr.decode("utf-8", errors="replace").strip()
        if progress:
            progress.update(raw, "error", err)
        raise RuntimeError(f"failed to download {host}:{remote_path}: {err}")
    tmp.replace(dest)
    write_cache_meta(dest, host, remote_path, remote_stat)
    final_size = dest.stat().st_size
    if progress:
        progress.update(raw, "done", str(dest), transferred=final_size, total=total or final_size, speed=0)
    return dest


PLY_SCALAR_TYPES = {
    "char": ("i1", 1),
    "int8": ("i1", 1),
    "uchar": ("u1", 1),
    "uint8": ("u1", 1),
    "short": ("i2", 2),
    "int16": ("i2", 2),
    "ushort": ("u2", 2),
    "uint16": ("u2", 2),
    "int": ("i4", 4),
    "int32": ("i4", 4),
    "uint": ("u4", 4),
    "uint32": ("u4", 4),
    "float": ("f4", 4),
    "float32": ("f4", 4),
    "double": ("f8", 8),
    "float64": ("f8", 8),
}

PLY_STRUCT_FORMATS = {
    "char": "b",
    "int8": "b",
    "uchar": "B",
    "uint8": "B",
    "short": "h",
    "int16": "h",
    "ushort": "H",
    "uint16": "H",
    "int": "i",
    "int32": "i",
    "uint": "I",
    "uint32": "I",
    "float": "f",
    "float32": "f",
    "double": "d",
    "float64": "d",
}

NORMALIZABLE_MESH_SUFFIXES = {".ply", ".obj", ".glb"}


def is_normalizable_mesh(path):
    return Path(path).suffix.lower() in NORMALIZABLE_MESH_SUFFIXES


def normalized_cache_path_for_source(cache_dir, source_path):
    cache_dir = Path(cache_dir)
    source_path = Path(source_path)
    try:
        rel = source_path.relative_to(cache_dir / "files")
    except ValueError:
        rel = Path(stable_key(str(source_path))) / source_path.name
    return cache_dir / "normalized_v1" / rel


def normalize_points_to_unit_cube(points):
    import numpy as np

    if points.size == 0:
        return points
    mins = points.min(axis=0)
    maxs = points.max(axis=0)
    center = (mins + maxs) * 0.5
    extent = float((maxs - mins).max())
    scale = 1.0 if extent <= 0 else 2.0 / extent
    return (points - center) * scale


def read_ply_header(path):
    marker = b"end_header"
    data = bytearray()
    with Path(path).open("rb") as handle:
        while True:
            chunk = handle.read(8192)
            if not chunk:
                raise RuntimeError(f"invalid PLY header: {path}")
            data.extend(chunk)
            marker_at = data.find(marker)
            if marker_at >= 0:
                newline_at = data.find(b"\n", marker_at)
                if newline_at >= 0:
                    header_end = newline_at + 1
                    header = bytes(data[:header_end])
                    return header, header_end


def parse_ply_header(header):
    text = header.decode("ascii", errors="strict")
    lines = text.replace("\r\n", "\n").replace("\r", "\n").splitlines()
    if not lines or lines[0].strip() != "ply":
        raise RuntimeError("not a PLY file")

    ply_format = None
    elements = []
    current = None
    for line in lines:
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "format" and len(parts) >= 2:
            ply_format = parts[1]
        elif parts[0] == "element" and len(parts) >= 3:
            current = {"name": parts[1], "count": int(parts[2]), "properties": []}
            elements.append(current)
        elif parts[0] == "property" and current is not None:
            if len(parts) >= 5 and parts[1] == "list":
                current["properties"].append(("list", parts[2], parts[3], parts[4]))
            elif len(parts) >= 3:
                current["properties"].append(("scalar", parts[1], parts[2]))

    if ply_format not in ("ascii", "binary_little_endian", "binary_big_endian"):
        raise RuntimeError(f"unsupported PLY format: {ply_format}")
    return ply_format, elements


def fixed_ply_element_size(element):
    size = 0
    for prop in element["properties"]:
        if prop[0] == "list":
            return None
        type_name = prop[1]
        if type_name not in PLY_SCALAR_TYPES:
            raise RuntimeError(f"unsupported PLY scalar type: {type_name}")
        size += PLY_SCALAR_TYPES[type_name][1]
    return size


def has_list_property(element):
    return any(prop[0] == "list" for prop in element["properties"])


def ply_vertex_layout(elements, header_end):
    offset = header_end
    for element in elements:
        if element["name"] == "vertex":
            props = element["properties"]
            names = [prop[-1] for prop in props]
            if any(prop[0] == "list" for prop in props):
                raise RuntimeError("unsupported PLY vertex list property")
            for axis in ("x", "y", "z"):
                if axis not in names:
                    raise RuntimeError(f"PLY vertex is missing {axis}")
            return offset, element

        element_size = fixed_ply_element_size(element)
        if element_size is None:
            raise RuntimeError("unsupported PLY layout: list element appears before vertex")
        offset += element_size * element["count"]

    raise RuntimeError("PLY has no vertex element")


def ply_scalar_size(type_name):
    if type_name not in PLY_SCALAR_TYPES:
        raise RuntimeError(f"unsupported PLY scalar type: {type_name}")
    return PLY_SCALAR_TYPES[type_name][1]


def ply_struct_format(type_name, endian):
    if type_name not in PLY_STRUCT_FORMATS:
        raise RuntimeError(f"unsupported PLY scalar type: {type_name}")
    return endian + PLY_STRUCT_FORMATS[type_name]


def read_ply_scalar(buffer, offset, type_name, endian):
    fmt = ply_struct_format(type_name, endian)
    return struct.unpack_from(fmt, buffer, offset)[0], offset + struct.calcsize(fmt)


def skip_binary_ply_element(buffer, offset, element, endian):
    fixed_size = fixed_ply_element_size(element)
    if fixed_size is not None:
        return offset + fixed_size * element["count"]

    for _ in range(element["count"]):
        for prop in element["properties"]:
            if prop[0] == "scalar":
                offset += ply_scalar_size(prop[1])
            else:
                _kind, count_type, item_type, _name = prop
                count, offset = read_ply_scalar(buffer, offset, count_type, endian)
                offset += int(count) * ply_scalar_size(item_type)
    return offset


def find_binary_ply_element_offset(buffer, elements, header_end, element_name, endian):
    offset = header_end
    for element in elements:
        if element["name"] == element_name:
            return offset, element
        offset = skip_binary_ply_element(buffer, offset, element, endian)
    raise RuntimeError(f"PLY has no {element_name} element")


def collect_binary_vertex_points(buffer, vertex_offset, vertex_element, endian):
    import numpy as np

    points = []
    coord_offsets = []
    coord_types = []
    offset = vertex_offset
    for _ in range(vertex_element["count"]):
        point = {}
        point_offsets = {}
        point_types = {}
        for prop in vertex_element["properties"]:
            if prop[0] == "scalar":
                _kind, type_name, name = prop
                value, next_offset = read_ply_scalar(buffer, offset, type_name, endian)
                if name in ("x", "y", "z"):
                    point[name] = value
                    point_offsets[name] = offset
                    point_types[name] = type_name
                offset = next_offset
            else:
                _kind, count_type, item_type, _name = prop
                count, offset = read_ply_scalar(buffer, offset, count_type, endian)
                offset += int(count) * ply_scalar_size(item_type)

        if not all(axis in point for axis in ("x", "y", "z")):
            raise RuntimeError("PLY vertex is missing x/y/z")
        points.append([point["x"], point["y"], point["z"]])
        coord_offsets.append([point_offsets["x"], point_offsets["y"], point_offsets["z"]])
        coord_types.append([point_types["x"], point_types["y"], point_types["z"]])

    return np.asarray(points, dtype=np.float64), coord_offsets, coord_types


def write_binary_vertex_points(buffer, normalized, coord_offsets, coord_types, endian):
    for point, offsets, types in zip(normalized, coord_offsets, coord_types):
        for value, offset, type_name in zip(point, offsets, types):
            if type_name not in ("float", "float32", "double", "float64"):
                raise RuntimeError(f"unsupported PLY coordinate type for normalization: {type_name}")
            struct.pack_into(ply_struct_format(type_name, endian), buffer, offset, float(value))


def normalize_binary_ply_with_lists(source, dest, ply_format, elements, header_end):
    import mmap

    endian = "<" if ply_format == "binary_little_endian" else ">"
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(f"{dest.name}.part.{os.getpid()}.{uuid.uuid4().hex}")
    shutil.copyfile(source, tmp)
    try:
        with tmp.open("r+b") as handle:
            with mmap.mmap(handle.fileno(), 0) as mapped:
                vertex_offset, vertex_element = find_binary_ply_element_offset(
                    mapped, elements, header_end, "vertex", endian
                )
                points, coord_offsets, coord_types = collect_binary_vertex_points(
                    mapped, vertex_offset, vertex_element, endian
                )
                normalized = normalize_points_to_unit_cube(points)
                write_binary_vertex_points(mapped, normalized, coord_offsets, coord_types, endian)
                mapped.flush()
        tmp.replace(dest)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def normalize_binary_ply(source, dest, ply_format, elements, header_end):
    import numpy as np

    endian = "<" if ply_format == "binary_little_endian" else ">"
    vertex_element = next((element for element in elements if element["name"] == "vertex"), None)
    if vertex_element is None:
        raise RuntimeError("PLY has no vertex element")
    if has_list_property(vertex_element):
        normalize_binary_ply_with_lists(source, dest, ply_format, elements, header_end)
        return

    try:
        vertex_offset, vertex_element = ply_vertex_layout(elements, header_end)
    except RuntimeError as exc:
        if "list element appears before vertex" not in str(exc):
            raise
        normalize_binary_ply_with_lists(source, dest, ply_format, elements, header_end)
        return

    dtype_fields = []
    for prop in vertex_element["properties"]:
        _kind, type_name, name = prop
        dtype_code, _size = PLY_SCALAR_TYPES[type_name]
        dtype_fields.append((name, endian + dtype_code))

    dtype = np.dtype(dtype_fields)
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(f"{dest.name}.part.{os.getpid()}.{uuid.uuid4().hex}")
    shutil.copyfile(source, tmp)
    try:
        vertices = np.memmap(tmp, dtype=dtype, mode="r+", offset=vertex_offset, shape=(vertex_element["count"],))
        points = np.column_stack([vertices["x"], vertices["y"], vertices["z"]]).astype(np.float64, copy=False)
        normalized = normalize_points_to_unit_cube(points)
        vertices["x"] = normalized[:, 0]
        vertices["y"] = normalized[:, 1]
        vertices["z"] = normalized[:, 2]
        vertices.flush()
        del vertices
        tmp.replace(dest)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def format_coord(value):
    return f"{float(value):.9g}"


def normalize_ascii_ply(source, dest, elements):
    import numpy as np

    text = Path(source).read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines(keepends=True)
    header_end = next((i + 1 for i, line in enumerate(lines) if line.strip() == "end_header"), None)
    if header_end is None:
        raise RuntimeError("invalid ASCII PLY header")

    vertex_start = header_end
    vertex_element = None
    for element in elements:
        if element["name"] == "vertex":
            vertex_element = element
            break
        vertex_start += element["count"]
    if vertex_element is None:
        raise RuntimeError("PLY has no vertex element")

    prop_names = [prop[-1] for prop in vertex_element["properties"]]
    axis_indices = [prop_names.index(axis) for axis in ("x", "y", "z")]
    vertex_end = vertex_start + vertex_element["count"]
    points = []
    split_lines = []
    for line in lines[vertex_start:vertex_end]:
        parts = line.strip().split()
        split_lines.append((parts, "\n" if line.endswith("\n") else ""))
        points.append([float(parts[i]) for i in axis_indices])

    normalized = normalize_points_to_unit_cube(np.asarray(points, dtype=np.float64))
    out_lines = list(lines)
    for offset, (parts, newline) in enumerate(split_lines):
        for coord_index, value in zip(axis_indices, normalized[offset]):
            parts[coord_index] = format_coord(value)
        out_lines[vertex_start + offset] = " ".join(parts) + newline

    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(f"{dest.name}.part.{os.getpid()}.{uuid.uuid4().hex}")
    tmp.write_text("".join(out_lines), encoding="utf-8")
    tmp.replace(dest)


def normalize_ply(source, dest):
    header, header_end = read_ply_header(source)
    ply_format, elements = parse_ply_header(header)
    if ply_format == "ascii":
        normalize_ascii_ply(source, dest, elements)
    else:
        normalize_binary_ply(source, dest, ply_format, elements, header_end)


def normalize_obj(source, dest):
    import numpy as np

    lines = Path(source).read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    vertex_rows = []
    points = []
    for index, line in enumerate(lines):
        if not line.startswith("v "):
            continue
        parts = line.strip().split()
        if len(parts) < 4:
            continue
        vertex_rows.append((index, parts, "\n" if line.endswith("\n") else ""))
        points.append([float(parts[1]), float(parts[2]), float(parts[3])])

    if not points:
        raise RuntimeError("OBJ has no vertex positions")

    normalized = normalize_points_to_unit_cube(np.asarray(points, dtype=np.float64))
    for offset, (index, parts, newline) in enumerate(vertex_rows):
        parts[1] = format_coord(normalized[offset, 0])
        parts[2] = format_coord(normalized[offset, 1])
        parts[3] = format_coord(normalized[offset, 2])
        lines[index] = " ".join(parts) + newline

    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(f"{dest.name}.part.{os.getpid()}.{uuid.uuid4().hex}")
    tmp.write_text("".join(lines), encoding="utf-8")
    tmp.replace(dest)


GLB_MAGIC = b"glTF"
GLB_VERSION = 2
GLB_JSON_CHUNK = b"JSON"
GLB_BIN_CHUNK = b"BIN\x00"


def parse_glb(path):
    data = Path(path).read_bytes()
    if len(data) < 12 or data[:4] != GLB_MAGIC:
        raise RuntimeError("not a GLB file")

    version, total_length = struct.unpack_from("<II", data, 4)
    if version != GLB_VERSION:
        raise RuntimeError(f"unsupported GLB version: {version}")
    if total_length > len(data):
        raise RuntimeError("invalid GLB length")

    offset = 12
    json_chunk = None
    bin_chunk = None
    extra_chunks = []
    while offset + 8 <= total_length:
        chunk_length, chunk_type = struct.unpack_from("<I4s", data, offset)
        offset += 8
        chunk = data[offset : offset + chunk_length]
        offset += chunk_length
        if chunk_type == GLB_JSON_CHUNK:
            json_chunk = chunk
        elif chunk_type == GLB_BIN_CHUNK:
            bin_chunk = bytearray(chunk)
        else:
            extra_chunks.append((chunk_type, chunk))

    if json_chunk is None:
        raise RuntimeError("GLB has no JSON chunk")
    if bin_chunk is None:
        raise RuntimeError("GLB has no BIN chunk")

    gltf = json.loads(json_chunk.rstrip(b" \t\r\n\x00").decode("utf-8"))
    return gltf, bin_chunk, extra_chunks


def padded_chunk(data, pad_byte):
    padding = (-len(data)) % 4
    return data + pad_byte * padding


def write_glb(path, gltf, bin_chunk, extra_chunks=None):
    json_data = json.dumps(gltf, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    json_data = padded_chunk(json_data, b" ")
    bin_data = padded_chunk(bytes(bin_chunk), b"\x00")
    chunks = [(GLB_JSON_CHUNK, json_data), (GLB_BIN_CHUNK, bin_data)]
    chunks.extend(extra_chunks or [])

    total_length = 12 + sum(8 + len(chunk) for _chunk_type, chunk in chunks)
    out = bytearray()
    out.extend(GLB_MAGIC)
    out.extend(struct.pack("<II", GLB_VERSION, total_length))
    for chunk_type, chunk in chunks:
        out.extend(struct.pack("<I4s", len(chunk), chunk_type))
        out.extend(chunk)

    Path(path).write_bytes(out)


def glb_position_array(gltf, bin_chunk, accessor_index):
    import numpy as np

    accessor = gltf["accessors"][accessor_index]
    if accessor.get("sparse"):
        raise RuntimeError("unsupported GLB sparse POSITION accessor")
    if accessor.get("componentType") != 5126 or accessor.get("type") != "VEC3":
        raise RuntimeError("unsupported GLB POSITION accessor; expected float32 VEC3")

    buffer_view = gltf["bufferViews"][accessor["bufferView"]]
    if buffer_view.get("buffer", 0) != 0:
        raise RuntimeError("unsupported GLB external buffer")

    count = int(accessor["count"])
    offset = int(buffer_view.get("byteOffset", 0)) + int(accessor.get("byteOffset", 0))
    stride = int(buffer_view.get("byteStride", 12))
    if offset + stride * max(count - 1, 0) + 12 > len(bin_chunk):
        raise RuntimeError("GLB POSITION accessor exceeds BIN chunk")

    return np.ndarray(
        shape=(count, 3),
        dtype=np.dtype("<f4"),
        buffer=bin_chunk,
        offset=offset,
        strides=(stride, 4),
    )


def glb_position_accessors(gltf):
    accessors = []
    seen = set()
    for mesh in gltf.get("meshes", []):
        for primitive in mesh.get("primitives", []):
            accessor_index = primitive.get("attributes", {}).get("POSITION")
            if accessor_index is not None and accessor_index not in seen:
                seen.add(accessor_index)
                accessors.append(accessor_index)
    return accessors


def normalize_glb(source, dest):
    import numpy as np

    gltf, bin_chunk, extra_chunks = parse_glb(source)
    accessor_indices = glb_position_accessors(gltf)
    if not accessor_indices:
        raise RuntimeError("GLB has no POSITION accessors")

    arrays = [glb_position_array(gltf, bin_chunk, index) for index in accessor_indices]
    mins = np.vstack([array.min(axis=0).astype(np.float64) for array in arrays]).min(axis=0)
    maxs = np.vstack([array.max(axis=0).astype(np.float64) for array in arrays]).max(axis=0)
    center = (mins + maxs) * 0.5
    extent = float((maxs - mins).max())
    scale = 1.0 if extent <= 0 else 2.0 / extent

    for accessor_index, array in zip(accessor_indices, arrays):
        normalized = (array.astype(np.float64) - center) * scale
        array[:] = normalized.astype(np.float32)
        gltf["accessors"][accessor_index]["min"] = [float(v) for v in normalized.min(axis=0)]
        gltf["accessors"][accessor_index]["max"] = [float(v) for v in normalized.max(axis=0)]

    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(f"{dest.name}.part.{os.getpid()}.{uuid.uuid4().hex}")
    try:
        write_glb(tmp, gltf, bin_chunk, extra_chunks)
        tmp.replace(dest)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def normalize_mesh_file(source, dest):
    suffix = Path(source).suffix.lower()
    if suffix == ".ply":
        normalize_ply(source, dest)
    elif suffix == ".obj":
        normalize_obj(source, dest)
    elif suffix == ".glb":
        normalize_glb(source, dest)
    else:
        raise RuntimeError(f"unsupported mesh format for normalization: {suffix}")
    return dest


def normalize_downloaded_mesh(raw, source, cache_dir, progress=None):
    source = Path(source)
    if not is_normalizable_mesh(source):
        return source

    dest = normalized_cache_path_for_source(cache_dir, source)
    if dest.exists() and dest.stat().st_size > 0 and dest.stat().st_mtime_ns >= source.stat().st_mtime_ns:
        if progress:
            size = dest.stat().st_size
            progress.update(raw, "normalized", str(dest), transferred=size, total=size, speed=0)
        return dest

    if progress:
        progress.update(raw, "normalizing", "target: [-1, 1]^3", transferred=0, total=source.stat().st_size, speed=0)
    normalize_mesh_file(source, dest)
    if progress:
        size = dest.stat().st_size
        progress.update(raw, "normalized", str(dest), transferred=size, total=size, speed=0)
    return dest


def collect_file_refs(tree):
    refs = []
    for elem in tree.getroot().iter():
        for attr in ("filename", "fileName"):
            value = elem.get(attr)
            if value:
                refs.append((elem, attr, value))
    return refs


def unique_missing_refs(refs, mlp_path):
    missing = []
    seen = set()
    for _elem, _attr, raw in refs:
        if raw in seen or local_path_for(raw, mlp_path).exists():
            continue
        seen.add(raw)
        missing.append(raw)
    return missing


def rewrite_project(mlp_path, config, refresh=False, progress=None):
    mlp_path = Path(mlp_path).expanduser().resolve()
    cache_dir = Path(config["cache_dir"])
    host = config["remote_host"]
    remote_root = config["remote_root"]

    tree = ET.parse(mlp_path)
    refs = collect_file_refs(tree)
    downloads = {}
    missing_refs = unique_missing_refs(refs, mlp_path)

    if missing_refs:
        if not host:
            raise RuntimeError("REMOTE_HOST is empty, cannot download missing files")
        if progress:
            progress.set_message(f"Checking {mlp_path.name}")
            for raw in missing_refs:
                progress.add(raw, raw)

        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, config["jobs"])) as pool:
            futures = {
                pool.submit(choose_remote_path, host, raw, mlp_path, remote_root, cache_dir, refresh, progress): raw
                for raw in missing_refs
            }
            for future in concurrent.futures.as_completed(futures):
                raw = futures[future]
                remote_selection = future.result()
                if remote_selection is None:
                    continue
                remote_path, remote_stat = remote_selection
                downloads[raw] = (remote_path, cache_path_for_remote(cache_dir, host, remote_path), remote_stat)

    if downloads:
        if progress:
            progress.set_message("Downloading files")
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, config["jobs"])) as pool:
            futures = [
                pool.submit(download_remote_file, host, raw, remote_path, dest, refresh, remote_stat, progress)
                for raw, (remote_path, dest, remote_stat) in downloads.items()
            ]
            for future in concurrent.futures.as_completed(futures):
                future.result()
        if progress:
            progress.set_message("Downloads complete")

    if downloads and config.get("normalize_meshes"):
        if progress:
            progress.set_message("Normalizing meshes to [-1, 1]^3")
        normalize_workers = max(1, min(config["jobs"], 2))
        with concurrent.futures.ThreadPoolExecutor(max_workers=normalize_workers) as pool:
            futures = {
                pool.submit(normalize_downloaded_mesh, raw, dest, cache_dir, progress): raw
                for raw, (_remote_path, dest, _remote_stat) in downloads.items()
                if is_normalizable_mesh(dest)
            }
            for future in concurrent.futures.as_completed(futures):
                raw = futures[future]
                remote_path, _dest, remote_stat = downloads[raw]
                downloads[raw] = (remote_path, future.result(), remote_stat)
        if progress:
            progress.set_message("Normalization complete")

    changed = False
    for elem, attr, raw in refs:
        expanded = os.path.expanduser(raw)
        if raw in downloads:
            elem.set(attr, str(downloads[raw][1]))
            changed = True
        elif not Path(expanded).is_absolute():
            local_candidate = local_path_for(raw, mlp_path)
            if local_candidate.exists():
                elem.set(attr, str(local_candidate))
                changed = True

    if not changed:
        if progress:
            progress.set_message("No rewrite needed")
        return mlp_path

    project_key = stable_key(str(mlp_path) + ":" + str(mlp_path.stat().st_mtime_ns))
    out_dir = cache_dir / "projects" / f"{mlp_path.stem}-{project_key}"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / mlp_path.name
    tree.write(out_path, encoding="utf-8", xml_declaration=False)
    logging.info("rewrote project: %s -> %s", mlp_path, out_path)
    if progress:
        progress.set_message(f"Opening {out_path.name}")
    return out_path


def open_with_meshlab(project_path, meshlab_app):
    app = user_path(meshlab_app)
    if not app.exists():
        raise RuntimeError(f"MeshLab app not found: {app}")
    subprocess.Popen(["open", "-a", str(app), str(project_path)])


def main(argv=None):
    parser = argparse.ArgumentParser(description="Download remote .mlp mesh refs over SSH, then open in MeshLab.")
    parser.add_argument("mlp", nargs="*", help="One or more local .mlp files")
    parser.add_argument("--host", help="Override REMOTE_HOST from config")
    parser.add_argument("--configure", action="store_true", help="Open the small SSH/root config UI")
    parser.add_argument("--refresh", dest="refresh", action="store_true", default=True, help="Check remote files and update stale cache entries")
    parser.add_argument("--no-refresh", dest="refresh", action="store_false", help="Use local cache without checking remote files")
    parser.add_argument("--no-open", action="store_true", help="Rewrite/download only; do not launch MeshLab")
    parser.add_argument("--progress-json", action="store_true", help="Emit JSON progress events for the macOS app")
    args = parser.parse_args(argv)

    if args.configure:
        return configure_ui()
    if not args.mlp:
        parser.error("missing .mlp file")

    config = read_config()
    if args.host:
        config["remote_host"] = args.host
    log_file = setup_logging(config["cache_dir"])
    progress = ProgressReporter(enabled=args.progress_json)

    try:
        outputs = []
        for mlp in args.mlp:
            progress.set_message(f"Opening {Path(mlp).name}")
            output = rewrite_project(mlp, config, refresh=args.refresh, progress=progress)
            outputs.append(output)
            if not args.no_open:
                open_with_meshlab(output, config["meshlab_app"])
        if args.progress_json:
            progress.complete(outputs)
        else:
            print("\n".join(str(p) for p in outputs))
        return 0
    except Exception as exc:
        logging.exception("ssh_mlp failed")
        progress.error(str(exc))
        notify(APP_NAME, f"{exc}\nSee {log_file}")
        print(f"{APP_NAME}: {exc}", file=sys.stderr)
        print(f"log: {log_file}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
