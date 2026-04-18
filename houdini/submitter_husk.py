#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
# This submitter targets the HuskStandalone Deadline plugin by pixel-ninja,
# licensed under GPL-3.0: https://github.com/pixel-ninja/HuskStandaloneSubmitter
#
import os
import re
import shlex
import tempfile
import subprocess
import hou

# ---------------------------------------------------------------------------
# HDA Setup Notes (Husk Submitter)
# ---------------------------------------------------------------------------
# Button callback:
#   kwargs["node"].hdaModule().submit_to_deadline(kwargs)
#
# Required parms:
#   usd_file, f1, f2
#
# Recommended Deadline parms:
#   batch_name, pool, deadline_group (or group), priority, machine_limit
#   deadline_machine_list (or machine_list), worker, deadline_plugin
#   sanity_check, submit_suspended
#
# Farm wake (optional):
#   Enable toggle: wake_farm_on_submit
#   Script path:   wake_farm_script (or wake_farm_script_path)
#   Script args:   wake_farm_script_args
#   Debug toggle:  wake_farm_debug
#   Fallback command parms:
#     submit_bash_command / pre_submit_command / farm_wake_command
#
# Karma overrides (optional):
#   update_karma_render_settings (or karma_settings_override)
#   pathtracedsamples_override (or karma_pathtracedsamples/pathtracedsamples)
#   karma_denoiser menu values:
#     - none  (No Denoiser)
#     - optix (NVIDIA OptiX Denoiser)
#
# ---------------------------------------------------------------------------
# Path Mapping: Local Mac -> Linux Farm
# ---------------------------------------------------------------------------
# Loaded from secrets.py (not tracked by git).
# See secrets.example.py for the template.
try:
    from secrets import PATH_MAP
except ImportError:
    PATH_MAP = {}


def remap_path(path):
    """Remap local paths to farm paths. Passthrough on Windows."""
    if os.name == "nt" or not path:
        return path
    normalized = str(path).replace("\\", "/")
    for local_root, farm_root in PATH_MAP.items():
        local_norm = str(local_root).replace("\\", "/")
        if normalized.startswith(local_norm):
            return "{}{}".format(farm_root, normalized[len(local_norm) :])
    return path


def _parm(node, name, default=None):
    """Safely evaluate a node parm with a default fallback."""
    p = node.parm(name)
    if p is None:
        return default
    return p.eval()


def _show(msg, severity=hou.severityType.Message):
    hou.ui.displayMessage(msg, severity=severity)


def _normalize_camera(camera):
    if not camera:
        return ""
    return camera if camera.startswith("/") else "/" + camera


def _inspect_stage(stage, camera_override):
    """
    Single pass over the stage for stats + camera sanity checks.
    Returns (stats, ok, warning_triggered).
    """
    stats = {
        "output_path": "Nicht gefunden (Pruefe RenderProduct Prims)",
        "meshes": 0,
        "lights": 0,
        "materials": 0,
        "instances": 0,
        "prims_total": 0,
    }
    camera_paths = set()
    render_settings_targets = []

    for prim in stage.Traverse():
        stats["prims_total"] += 1
        type_name = prim.GetTypeName()

        if type_name == "Mesh":
            stats["meshes"] += 1
        elif "Light" in type_name:
            stats["lights"] += 1
        elif type_name == "Material":
            stats["materials"] += 1
        elif type_name == "Camera":
            camera_paths.add(str(prim.GetPath()))
        elif type_name == "RenderSettings":
            rel = prim.GetRelationship("camera")
            if rel:
                targets = rel.GetTargets()
                if targets:
                    render_settings_targets.append((str(prim.GetPath()), str(targets[0])))

        if prim.IsInstance():
            stats["instances"] += 1

        if type_name == "RenderProduct":
            product_attr = prim.GetAttribute("productName")
            if product_attr:
                value = product_attr.Get(hou.frame()) or product_attr.Get()
                if value:
                    stats["output_path"] = str(value)

    cameras = sorted(camera_paths)
    if camera_override:
        cam_path = _normalize_camera(camera_override)
        if not cameras:
            result = hou.ui.displayMessage(
                "Sanity Check Warnung: Es wurde keine Kamera im verbundenen LOP-Graphen gefunden.\n"
                "Husk benoetigt eine Kamera zum Rendern.\n\n"
                "Moechten Sie den Job trotzdem abschicken?",
                buttons=("Abbrechen", "Trotzdem Senden"),
                severity=hou.severityType.Warning,
            )
            return (stats, result != 0, True)
        if cam_path not in camera_paths:
            found = "\n- ".join([""] + cameras)
            result = hou.ui.displayMessage(
                "Warnung: Die Override-Kamera existiert nicht in der aktuellen LOP-Stage.\n\n"
                "Override: {}\n"
                "Gefundene Kameras:{}\n\n"
                "Moechten Sie den Job trotzdem abschicken?".format(cam_path, found),
                buttons=("Abbrechen", "Trotzdem Senden"),
                severity=hou.severityType.Warning,
            )
            return (stats, result != 0, True)
        return (stats, True, False)

    invalid = [(rs_path, cam) for rs_path, cam in render_settings_targets if cam not in camera_paths]
    if invalid:
        msg = "Sanity Check Warnung: Ein RenderSettings-Prim verweist auf eine fehlende Kamera.\n\n"
        for rs_path, broken_cam in invalid:
            msg += "Settings Prim: {}\n-> Fehlende Kamera: {}\n\n".format(rs_path, broken_cam)
        msg += "Husk wird voraussichtlich abbrechen.\nMoechten Sie den Job trotzdem abschicken?"
        result = hou.ui.displayMessage(
            msg,
            buttons=("Abbrechen", "Trotzdem Senden"),
            severity=hou.severityType.Warning,
        )
        return (stats, result != 0, True)

    if not cameras:
        result = hou.ui.displayMessage(
            "Sanity Check Warnung: Es wurde keine Kamera im verbundenen LOP-Graphen gefunden.\n"
            "Husk benoetigt eine Kamera zum Rendern.\n\n"
            "Moechten Sie den Job trotzdem abschicken?",
            buttons=("Abbrechen", "Trotzdem Senden"),
            severity=hou.severityType.Warning,
        )
        return (stats, result != 0, True)

    return (stats, True, False)


def _resolve_deadlinecommand():
    env_path = os.environ.get("DEADLINE_PATH", "")
    exe = "deadlinecommand.exe" if os.name == "nt" else "deadlinecommand"
    env_path = str(env_path).strip()

    if env_path:
        if os.path.isfile(env_path):
            return env_path
        candidate = os.path.join(env_path, exe)
        if os.path.isfile(candidate):
            return candidate

    # Common default installs
    candidates = []
    if os.name == "nt":
        candidates.append(r"C:\Program Files\Thinkbox\Deadline10\bin\deadlinecommand.exe")
    elif sys_platform() == "darwin":
        candidates.append("/Applications/Thinkbox/Deadline10/Resources/deadlinecommand")
    else:
        candidates.append("/opt/Thinkbox/Deadline10/bin/deadlinecommand")

    for c in candidates:
        if os.path.isfile(c):
            return c
    # Final fallback: rely on PATH lookup.
    return exe


def sys_platform():
    return os.uname().sysname.lower() if hasattr(os, "uname") else ""


def _write_job_files(job_info, plugin_info):
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-16", prefix="husk_job_info_", suffix=".job", delete=False
    ) as job_f:
        for line in job_info:
            job_f.write(line + "\n")
        job_path = job_f.name

    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-16", prefix="husk_plugin_info_", suffix=".job", delete=False
    ) as plugin_f:
        for line in plugin_info:
            plugin_f.write(line + "\n")
        plugin_path = plugin_f.name

    return job_path, plugin_path


def _run_optional_submit_command(node):
    """
    Optional farm wake hook via HDA parms.
    Supported checkbox parms:
      wake_farm_on_submit, trigger_farm_wake, run_submit_command, farm_wake_enabled
    Supported command parms:
      wake_farm_command, submit_bash_command, pre_submit_command, farm_wake_command
    Preferred custom script parms:
      wake_farm_script, wake_farm_script_path, wake_farm_script_args
    Optional debug checkbox parms:
      wake_farm_debug, submit_command_debug
    """
    enabled = 0
    for parm_name in (
        "wake_farm_on_submit",
        "trigger_farm_wake",
        "run_submit_command",
        "farm_wake_enabled",
        "wake_farm_command",
    ):
        if node.parm(parm_name) is not None:
            raw_enabled = _parm(node, parm_name, 0)
            try:
                enabled = int(raw_enabled or 0)
            except (TypeError, ValueError):
                enabled = 0
            break
    if not enabled:
        return "", False, ""

    script_path = ""
    for parm_name in ("wake_farm_script", "wake_farm_script_path"):
        if node.parm(parm_name) is None:
            continue
        value = str(_parm(node, parm_name, "") or "").strip()
        if value:
            script_path = value
            break

    script_args = str(_parm(node, "wake_farm_script_args", "") or "").strip()
    command = ""
    run_args = None

    if script_path:
        script_tokens = []
        if script_args:
            try:
                script_tokens = shlex.split(script_args)
            except ValueError as exc:
                _show(
                    "Ungueltige wake_farm_script_args (Quote-Fehler):\n{}\n\n{}".format(
                        script_args, exc
                    ),
                    severity=hou.severityType.Warning,
                )
                return "", False, ""
        else:
            # Convenience: allow "path/to/script.sh --arg" in the script field itself.
            try:
                inline_tokens = shlex.split(script_path)
            except ValueError as exc:
                _show(
                    "Ungueltige wake_farm_script Eingabe (Quote-Fehler):\n{}\n\n{}".format(
                        script_path, exc
                    ),
                    severity=hou.severityType.Warning,
                )
                return "", False, ""
            if len(inline_tokens) > 1:
                script_path = inline_tokens[0]
                script_tokens = inline_tokens[1:]

        if not os.path.isfile(script_path):
            _show(
                "Farm-Wake Script nicht gefunden:\n{}\n\n"
                "Nutze einen gueltigen absoluten Script-Pfad oder das Command-Feld.".format(
                    script_path
                ),
                severity=hou.severityType.Warning,
            )
            return "", False, ""

        if os.name == "nt":
            command = '"{}" {}'.format(script_path, " ".join(script_tokens)).strip()
            run_args = ["cmd", "/c", command]
        else:
            run_args = ["bash", script_path]
            if script_tokens:
                run_args.extend(script_tokens)
            command = " ".join([shlex.quote(token) for token in run_args])
    else:
        for parm_name in (
            "submit_bash_command",
            "pre_submit_command",
            "farm_wake_command",
            "wake_farm_command",
        ):
            if node.parm(parm_name) is None:
                continue
            value = str(_parm(node, parm_name, "") or "").strip()
            # If this parm is used as a toggle (0/1), do not treat it as shell command.
            if value in ("0", "1"):
                continue
            if value:
                command = value
                break

    if not command:
        _show(
            "Farm-Wake aktiv, aber kein Script/Command gesetzt.\n"
            "Nutze z.B. 'wake_farm_script' oder 'wake_farm_command'.",
            severity=hou.severityType.Warning,
        )
        return "", False, ""

    debug_mode = 0
    for parm_name in ("wake_farm_debug", "submit_command_debug"):
        if node.parm(parm_name) is not None:
            debug_mode = int(_parm(node, parm_name, 0) or 0)
            break

    log_path = os.path.join(tempfile.gettempdir(), "husk_farm_wake.log")

    try:
        if debug_mode:
            if run_args:
                proc = subprocess.run(run_args, capture_output=True, text=True)
            elif os.name == "nt":
                proc = subprocess.run(["cmd", "/c", command], capture_output=True, text=True)
            else:
                proc = subprocess.run(["bash", "-lc", command], capture_output=True, text=True)

            with open(log_path, "w", encoding="utf-8") as log_f:
                log_f.write("command: {}\n".format(command))
                log_f.write("returncode: {}\n\n".format(proc.returncode))
                log_f.write("--- stdout ---\n{}\n".format(proc.stdout or ""))
                log_f.write("--- stderr ---\n{}\n".format(proc.stderr or ""))

            if proc.returncode != 0:
                _show(
                    "Farm-Wake Command fehlgeschlagen (Exit Code {}).\nLog: {}\n\n{}".format(
                        proc.returncode, log_path, command
                    ),
                    severity=hou.severityType.Warning,
                )
                return command, False, log_path

            return command, True, log_path

        with open(log_path, "a", encoding="utf-8") as log_f:
            if run_args:
                subprocess.Popen(
                    run_args,
                    stdout=log_f,
                    stderr=log_f,
                    start_new_session=True,
                )
            elif os.name == "nt":
                subprocess.Popen(
                    ["cmd", "/c", command],
                    stdout=log_f,
                    stderr=log_f,
                    start_new_session=True,
                )
            else:
                subprocess.Popen(
                    ["bash", "-lc", command],
                    stdout=log_f,
                    stderr=log_f,
                    start_new_session=True,
                )
    except Exception as exc:
        _show(
            "Farm-Wake Command konnte nicht gestartet werden:\n{}\n\n{}".format(command, exc),
            severity=hou.severityType.Warning,
        )
        return command, False, log_path

    return command, True, log_path


def _is_wake_enabled(node):
    for parm_name in (
        "wake_farm_on_submit",
        "trigger_farm_wake",
        "run_submit_command",
        "farm_wake_enabled",
        "wake_farm_command",
    ):
        if node.parm(parm_name) is not None:
            raw_enabled = _parm(node, parm_name, 0)
            try:
                return bool(int(raw_enabled or 0))
            except (TypeError, ValueError):
                return False
    return False


def _normalize_machine_list(value):
    """Normalize CSV whitelist entries and drop empty items."""
    raw = str(value or "")
    return ",".join([item.strip() for item in raw.split(",") if item.strip()])


def _collect_upstream_nodes(start_node):
    """Collect upstream nodes from input 0 (including start node)."""
    if start_node is None:
        return []
    seen = set()
    stack = [start_node]
    ordered = []
    while stack:
        current = stack.pop()
        if current is None:
            continue
        path = current.path()
        if path in seen:
            continue
        seen.add(path)
        ordered.append(current)
        for in_node in current.inputs():
            if in_node is not None:
                stack.append(in_node)
    return ordered


def _read_karma_override_settings(node):
    enabled = int(_parm(node, "update_karma_render_settings", _parm(node, "karma_settings_override", 0)) or 0)
    if not enabled:
        return {"enabled": False, "samples": 0, "denoiser": ""}

    samples = int(
        _parm(
            node,
            "pathtracedsamples_override",
            _parm(node, "karma_pathtracedsamples", _parm(node, "pathtracedsamples", 0)),
        )
        or 0
    )

    denoiser_raw = _parm(node, "karma_denoiser", _parm(node, "denoiser", ""))
    denoiser_raw = str(denoiser_raw).strip().lower()
    if denoiser_raw in ("1", "optix", "nvidia optix denoiser", "nvidia_optix", "nvidia"):
        denoiser = "optix"
    elif denoiser_raw in ("0", "none", "no denoiser", "off", ""):
        denoiser = "none"
    else:
        denoiser = denoiser_raw

    return {"enabled": True, "samples": max(0, samples), "denoiser": denoiser}


def _set_first_existing_parm(nodes, parm_names, value):
    """Set first matching parm in node list."""
    for n in nodes:
        for parm_name in parm_names:
            p = n.parm(parm_name)
            if p is None:
                continue
            try:
                p.set(value)
                return "{}.{}".format(n.path(), parm_name)
            except Exception:
                continue
    return ""


def _set_first_matching_menu_parm(nodes, parm_names, mode):
    """
    mode: "none" or "optix".
    Tries to match menu token/label heuristically.
    """
    if mode not in ("none", "optix"):
        return ""
    preferred_terms = ("optix", "nvidia") if mode == "optix" else ("none", "off", "disable", "no")
    fallback_terms = ("none", "off") if mode == "none" else ("optix",)

    for n in nodes:
        for parm_name in parm_names:
            p = n.parm(parm_name)
            if p is None:
                continue

            try:
                menu_items = [str(i) for i in p.menuItems()]
                menu_labels = [str(l).lower() for l in p.menuLabels()]
            except Exception:
                menu_items = []
                menu_labels = []

            if menu_items:
                # Match by token first, then label.
                target_token = ""
                for token in menu_items:
                    t = token.lower()
                    if any(term in t for term in preferred_terms):
                        target_token = token
                        break
                if not target_token:
                    for idx, label in enumerate(menu_labels):
                        if any(term in label for term in preferred_terms):
                            target_token = menu_items[idx]
                            break
                if not target_token:
                    for token in menu_items:
                        t = token.lower()
                        if any(term in t for term in fallback_terms):
                            target_token = token
                            break
                if target_token:
                    try:
                        p.set(target_token)
                        return "{}.{}".format(n.path(), parm_name)
                    except Exception:
                        pass

            # Non-menu fallback
            try:
                p.set(mode)
                return "{}.{}".format(n.path(), parm_name)
            except Exception:
                continue
    return ""


def submit_to_deadline(kwargs):
    node = kwargs["node"]
    version = "{}.{}".format(hou.applicationVersion()[0], hou.applicationVersion()[1])

    usd_file = _parm(node, "usd_file", "")
    sequence_single_job = int(_parm(node, "sequence_single_job", 0))
    sanity_check = int(_parm(node, "sanity_check", 1))
    submit_suspended = int(_parm(node, "submit_suspended", 0))
    submit_as_suspended = bool(submit_suspended)
    start_frame = int(_parm(node, "f1", int(hou.playbar.frameRange()[0])))
    end_frame = int(_parm(node, "f2", int(hou.playbar.frameRange()[1])))
    chunk_size = int(_parm(node, "chunk_size", 1))
    batch_name = _parm(node, "batch_name", "") or ""

    # Optional parms
    camera = _parm(node, "camera", "") or ""
    renderer = _parm(node, "renderer", "") or ""
    pool = _parm(node, "pool", "")
    group = _parm(node, "deadline_group", _parm(node, "group", ""))
    priority = int(_parm(node, "priority", 50)) if node.parm("priority") else 50
    machine_limit = int(_parm(node, "machine_limit", 0)) if node.parm("machine_limit") else 0
    worker = str(_parm(node, "worker", "") or "").strip()
    machine_list = str(_parm(node, "deadline_machine_list", _parm(node, "machine_list", "")) or "")
    machine_list = _normalize_machine_list(machine_list)
    if worker and not machine_list:
        machine_list = worker
    comment = _parm(node, "comment", "")
    department = _parm(node, "department", "")
    plugin_name = _parm(node, "deadline_plugin", "gegenschuss_HuskStandaloneSubmission") or "gegenschuss_HuskStandaloneSubmission"

    if not usd_file:
        _show("Leerer USD Dateipfad.", severity=hou.severityType.Error)
        return

    stats = {
        "output_path": "Nicht gefunden (Pruefe RenderProduct Prims)",
        "meshes": 0,
        "lights": 0,
        "materials": 0,
        "instances": 0,
        "prims_total": 0,
    }

    # Live stage validation/stats
    input_nodes = node.inputs()
    root_input = input_nodes[0] if input_nodes else None
    camera_warning_triggered = False
    if input_nodes and hasattr(input_nodes[0], "stage"):
        try:
            stage = input_nodes[0].stage()
            if stage:
                stats, ok, camera_warning_triggered = _inspect_stage(stage, camera)
                if not ok:
                    return
        except Exception:
            # Keep submission robust even when stage introspection fails
            pass

    # If camera override exists but no LOP stage is connected, warn once.
    if camera and not camera_warning_triggered and not (input_nodes and hasattr(input_nodes[0], "stage")):
        result = hou.ui.displayMessage(
            "Hinweis: Override-Kamera ist gesetzt ('{}'), aber kein LOP-Graph ist verbunden.\n"
            "Existenz der Kamera kann nicht live geprueft werden.\n\n"
            "Trotzdem fortfahren?".format(camera),
            buttons=("Abbrechen", "Trotzdem Senden"),
            severity=hou.severityType.Warning,
        )
        if result == 0:
            return

    karma_settings = _read_karma_override_settings(node)
    karma_notes = []
    if karma_settings["enabled"]:
        upstream_nodes = _collect_upstream_nodes(root_input)
        if karma_settings["samples"] > 0:
            parm_ref = _set_first_existing_parm(
                upstream_nodes,
                ("pathtracedsamples", "samplesperpixel", "pixel_samples", "primarysamples"),
                karma_settings["samples"],
            )
            if parm_ref:
                karma_notes.append("Samples gesetzt ({}) -> {}".format(karma_settings["samples"], parm_ref))
            else:
                karma_notes.append(
                    "Samples Override aktiv ({}), kein passender LOP Parm gefunden".format(
                        karma_settings["samples"]
                    )
                )

        if karma_settings["denoiser"] in ("none", "optix"):
            denoiser_ref = _set_first_matching_menu_parm(
                upstream_nodes,
                ("denoiser", "denoise", "denoise_mode", "optix_denoiser", "karmadenoiser"),
                karma_settings["denoiser"],
            )
            if denoiser_ref:
                denoiser_label = "No Denoiser" if karma_settings["denoiser"] == "none" else "NVIDIA OptiX"
                karma_notes.append("Denoiser gesetzt ({}) -> {}".format(denoiser_label, denoiser_ref))
            else:
                karma_notes.append(
                    "Denoiser Override aktiv ({}), kein passender LOP Parm gefunden".format(
                        karma_settings["denoiser"]
                    )
                )

    remapped_usd_file = remap_path(usd_file)

    if sanity_check and not os.path.exists(usd_file):
        _show(
            "USD Datei existiert nicht auf der Festplatte.\n\n"
            "Bitte Pfad pruefen oder Sanity Check ausschalten.",
            severity=hou.severityType.Error,
        )
        return

    submit_usd_file = remapped_usd_file
    job_name = os.path.basename(remapped_usd_file)

    if sequence_single_job:
        base, ext = os.path.splitext(remapped_usd_file)
        match = re.search(r"(\d+)$", base)
        if not match:
            _show(
                "Konnte keine Framenummer im Dateinamen finden. Sequenz-Submit abgebrochen.",
                severity=hou.severityType.Error,
            )
            return

        padding = len(match.group(1))
        if padding != 4:
            result = hou.ui.displayMessage(
                "Padding-Warnung: Der Dateiname nutzt {} Ziffern.\n"
                "Pipeline-Standard ist $F4 (z.B. 0001).\n\n"
                "Trotzdem senden?".format(padding),
                buttons=("Abbrechen", "Senden"),
                severity=hou.severityType.Warning,
            )
            if result == 0:
                return

        submit_usd_file = base[: match.start()] + ("#" * padding) + ext
        job_name = os.path.basename(submit_usd_file)

    frame_list = "{}-{}".format(start_frame, end_frame)

    clean_job_name = re.sub(r"\.#+\.usd$", "", job_name)
    clean_job_name = re.sub(r"\.usd$", "", clean_job_name)
    final_job_name = batch_name if batch_name else clean_job_name

    job_info = [
        "Plugin={}".format(plugin_name),
        "Name={}".format(final_job_name),
        "Frames={}".format(frame_list),
        "ChunkSize={}".format(chunk_size),
    ]

    if batch_name:
        job_info.append("BatchName={}".format(batch_name))
    if pool:
        job_info.append("Pool={}".format(pool))
    if group:
        job_info.append("Group={}".format(group))
    if priority >= 0:
        job_info.append("Priority={}".format(priority))
    if machine_limit > 0:
        job_info.append("MachineLimit={}".format(machine_limit))
    if machine_list:
        # Deadline expects host list directly in Whitelist for job info.
        job_info.append("Whitelist={}".format(machine_list))
    if department:
        job_info.append("Department={}".format(department))
    if comment:
        job_info.append("Comment={}".format(comment))
    if submit_as_suspended:
        job_info.append("InitialStatus=Suspended")

    arguments = {
        "--usd-input": submit_usd_file,
        "--make-output-path": "",
    }
    if karma_settings["enabled"] and karma_settings["samples"] > 0:
        # Husk-native override; affects rendering even if no LOP parm could be set.
        arguments["--pixel-samples"] = str(karma_settings["samples"])
    if camera:
        arguments["--camera"] = _normalize_camera(camera)
    if renderer:
        arguments["--renderer"] = renderer

    plugin_info = [
        "Version={}".format(version),
        "Build=64bit",
        "ArgumentList={}".format(";".join(arguments.keys())),
    ]
    for key, value in arguments.items():
        plugin_info.append("{}={}".format(key, value))

    job_file, plugin_file = _write_job_files(job_info, plugin_info)
    deadline_cmd = _resolve_deadlinecommand()
    wake_enabled = _is_wake_enabled(node)
    wake_command, wake_started, wake_log_path = _run_optional_submit_command(node)

    try:
        result = subprocess.check_output([deadline_cmd, job_file, plugin_file], text=True)
    except subprocess.CalledProcessError as exc:
        _show(
            "Fehler bei der Deadline Submission:\n{}".format(exc.output),
            severity=hou.severityType.Error,
        )
        return
    except FileNotFoundError:
        _show(
            "Konnte 'deadlinecommand' nicht finden. Ist Deadline installiert?",
            severity=hou.severityType.Error,
        )
        return

    if "Result=Success" not in result:
        _show(
            "Warnung bei der Uebermittlung:\n{}".format(result),
            severity=hou.severityType.Warning,
        )
        return

    msg = "Job erfolgreich uebermittelt!\n\n{}".format(result)
    msg += "\n\n=== Submit Status ===\n"
    msg += "Initial Status: {}\n".format("Suspended" if submit_as_suspended else "Active")
    if machine_list:
        msg += "Worker Whitelist: {}\n".format(machine_list)

    msg += "\n=== Farm Wake ===\n"
    msg += "Trigger: {}\n".format("aktiv" if wake_enabled else "deaktiviert")
    if wake_enabled:
        if wake_command:
            msg += "Command: {}\n".format(wake_command)
            msg += "Status: {}\n".format("gestartet" if wake_started else "fehlgeschlagen")
            if wake_log_path:
                msg += "Log: {}\n".format(wake_log_path)
        else:
            msg += "Status: nicht ausgelost (kein Script/Command konfiguriert)\n"

    msg += "\n=== Karma Overrides ===\n"
    msg += "Enabled: {}\n".format("ja" if karma_settings["enabled"] else "nein")
    if karma_settings["enabled"]:
        msg += "Path Traced Samples: {}\n".format(
            karma_settings["samples"] if karma_settings["samples"] > 0 else "unveraendert"
        )
        if karma_settings["denoiser"] in ("none", "optix"):
            denoiser_label = "No Denoiser" if karma_settings["denoiser"] == "none" else "NVIDIA OptiX Denoiser"
            msg += "Denoiser: {}\n".format(denoiser_label)
        else:
            msg += "Denoiser: unveraendert\n"
        for note in karma_notes:
            msg += "- {}\n".format(note)

    msg += (
        "\n=== LOP Stage Stats ===\n"
        "Output Path: {}\n"
        "Total Prims: {}\n"
        "Meshes: {} | Instances: {}\n"
        "Lights: {} | Materials: {}".format(
            stats["output_path"],
            stats["prims_total"],
            stats["meshes"],
            stats["instances"],
            stats["lights"],
            stats["materials"],
        )
    )

    if usd_file != remapped_usd_file:
        msg += (
            "\n\n=== Path Remapping ===\n"
            "Local: {}\n"
            "Farm:  {}".format(usd_file, remapped_usd_file)
        )

    _show(msg)
