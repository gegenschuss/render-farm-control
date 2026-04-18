#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
import os
import shlex
import tempfile
import subprocess
import hou

# ---------------------------------------------------------------------------
# HDA Setup Notes (USD Export Submitter)
# ---------------------------------------------------------------------------
# Button callback:
#   kwargs["node"].hdaModule().submit_usd_export_to_deadline(kwargs)
#
# Optional helper button callback:
#   kwargs["node"].hdaModule().set_target_from_selection(kwargs)
#
# Required parms:
#   f1, f2, target_lop_path (or connect target node to input 0)
#
# Recommended Deadline parms:
#   batch_name, comment, department, pool, deadline_group (or group)
#   priority, machine_limit, deadline_machine_list (or machine_list), worker
#   submit_suspended
#
# Farm wake (optional):
#   Enable toggle: wake_farm_on_submit
#   Script path:   wake_farm_script (or wake_farm_script_path)
#   Script args:   wake_farm_script_args
#   Debug toggle:  wake_farm_debug
#   Fallback command parms:
#     submit_bash_command / pre_submit_command / farm_wake_command
#
# ---------------------------------------------------------------------------
# Path Mapping: Local -> Farm
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


def _show(message, severity=hou.severityType.Message):
    hou.ui.displayMessage(message, severity=severity)


def _parm(node, name, default=None):
    p = node.parm(name)
    if p is None:
        return default
    return p.eval()


def _normalize_machine_list(value):
    """Normalize CSV whitelist entries and drop empty items."""
    raw = str(value or "")
    return ",".join([item.strip() for item in raw.split(",") if item.strip()])


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

    if os.name != "nt":
        fallback = "/opt/Thinkbox/Deadline10/bin/deadlinecommand"
        if os.path.isfile(fallback):
            return fallback
    else:
        fallback = r"C:\Program Files\Thinkbox\Deadline10\bin\deadlinecommand.exe"
        if os.path.isfile(fallback):
            return fallback

    return exe


def _find_connected_lop_output_node(submitter_node):
    """
    We assume input 0 is the target LOP/USD output node to cook on farm.
    """
    inputs = submitter_node.inputs()
    if not inputs or inputs[0] is None:
        return None
    return inputs[0]


def _resolve_target_lop_node(submitter_node):
    """
    Resolve target node in this priority:
      1) target_lop_path parm (string/node path), if valid
      2) connected input 0
      3) single selected node in the current network editor
    """
    path_from_parm = str(_parm(submitter_node, "target_lop_path", "") or "").strip()
    if path_from_parm:
        node = hou.node(path_from_parm)
        if node is not None:
            return node, "parm"

    connected = _find_connected_lop_output_node(submitter_node)
    if connected is not None:
        return connected, "input"

    try:
        selected = hou.selectedNodes()
    except Exception:
        selected = []
    if len(selected) == 1:
        return selected[0], "selection"

    return None, "none"


def _find_output_usd_path(lop_node):
    """
    Best-effort read of USD output path from common parameter names.
    """
    candidates = (
        "lopoutput",
        "output",
        "outputfile",
        "usd_file",
        "filepath",
    )
    for name in candidates:
        p = lop_node.parm(name)
        if p is not None:
            val = p.eval()
            if val:
                return str(val), name
    return "", ""


def _write_deadline_files(job_lines, plugin_lines):
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-16", prefix="usdexport_job_info_", suffix=".job", delete=False
    ) as job_f:
        for line in job_lines:
            job_f.write(line + "\n")
        job_path = job_f.name

    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-16", prefix="usdexport_plugin_info_", suffix=".job", delete=False
    ) as plugin_f:
        for line in plugin_lines:
            plugin_f.write(line + "\n")
        plugin_path = plugin_f.name

    return job_path, plugin_path


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


def _run_optional_submit_command(node):
    enabled = _is_wake_enabled(node)
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

    log_path = os.path.join(tempfile.gettempdir(), "usdexport_farm_wake.log")

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


def submit_usd_export_to_deadline(kwargs):
    """
    Submit a Deadline Houdini job that cooks a connected LOP/USD output node
    and writes USD files (not images).

    HDA button callback:
      kwargs["node"].hdaModule().submit_usd_export_to_deadline(kwargs)
    """
    node = kwargs["node"]

    # Resolve target node without requiring a wire.
    target_node, target_source = _resolve_target_lop_node(node)
    if target_node is None:
        _show(
            "Kein Ziel-LOP Node gefunden.\n\n"
            "Bitte eine der folgenden Optionen nutzen:\n"
            "1) Parm 'target_lop_path' setzen (empfohlen), oder\n"
            "2) Input 0 verbinden, oder\n"
            "3) genau einen Node selektieren.",
            severity=hou.severityType.Error,
        )
        return

    output_driver_path = target_node.path()
    output_usd_local, output_usd_parm = _find_output_usd_path(target_node)
    output_usd_farm = remap_path(output_usd_local) if output_usd_local else ""

    # Validate HIP file is saved.
    hip_local = hou.hipFile.path()
    if not hip_local or hip_local.lower() in ("untitled.hip", "untitled.hiplc", "untitled.hipnc"):
        _show(
            "Bitte speichere die HIP Datei vor dem Submit.",
            severity=hou.severityType.Error,
        )
        return
    if not os.path.exists(hip_local):
        _show(
            "HIP Datei wurde nicht gefunden:\n{}".format(hip_local),
            severity=hou.severityType.Error,
        )
        return

    hip_farm = remap_path(hip_local)

    start_frame = int(_parm(node, "f1", int(hou.playbar.frameRange()[0])))
    end_frame = int(_parm(node, "f2", int(hou.playbar.frameRange()[1])))
    if end_frame < start_frame:
        _show("Ungueltiger Frame-Bereich: End < Start.", severity=hou.severityType.Error)
        return

    chunk_size = int(_parm(node, "chunk_size", 1))
    batch_name = str(_parm(node, "batch_name", "") or "")
    comment = str(_parm(node, "comment", "") or "")
    department = str(_parm(node, "department", "") or "")
    pool = str(_parm(node, "pool", "") or "")
    group = str(_parm(node, "deadline_group", _parm(node, "group", "")) or "")
    priority = int(_parm(node, "priority", 50)) if node.parm("priority") else 50
    machine_limit = int(_parm(node, "machine_limit", 0)) if node.parm("machine_limit") else 0

    # Worker pinning: worker (single) or machine_list (csv)
    worker = str(_parm(node, "worker", "") or "").strip()
    machine_list = str(_parm(node, "deadline_machine_list", _parm(node, "machine_list", "")) or "")
    machine_list = _normalize_machine_list(machine_list)
    if worker and not machine_list:
        machine_list = worker

    # Explicit submit mode option:
    # - submit_suspended=1 forces suspended submission.
    submit_suspended = int(_parm(node, "submit_suspended", 0))
    submit_as_suspended = bool(submit_suspended)

    version = "{}.{}".format(hou.applicationVersion()[0], hou.applicationVersion()[1])
    job_name = batch_name if batch_name else "USD Export - {}".format(target_node.name())

    # Deadline job/plugin files for Houdini plugin.
    job_info = [
        "Plugin=Houdini",
        "Name={}".format(job_name),
        "Frames={}-{}".format(start_frame, end_frame),
        "ChunkSize={}".format(chunk_size),
    ]
    if batch_name:
        job_info.append("BatchName={}".format(batch_name))
    if comment:
        job_info.append("Comment={}".format(comment))
    if department:
        job_info.append("Department={}".format(department))
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
    if output_usd_farm:
        job_info.append("OutputFilename0={}".format(output_usd_farm))
    if submit_as_suspended:
        job_info.append("InitialStatus=Suspended")

    plugin_info = [
        "SceneFile={}".format(hip_farm),
        "OutputDriver={}".format(output_driver_path),
        "Version={}".format(version),
        "Build=64bit",
        "IgnoreInputs=false",
    ]

    job_file, plugin_file = _write_deadline_files(job_info, plugin_info)
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
            "Konnte 'deadlinecommand' nicht finden.\n"
            "Pruefe DEADLINE_PATH oder Deadline Installation.",
            severity=hou.severityType.Error,
        )
        return

    if "Result=Success" not in result:
        _show("Warnung bei der Uebermittlung:\n{}".format(result), severity=hou.severityType.Warning)
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

    msg += "\n=== Submission Inputs ===\n"
    msg += "HIP (local): {}\n".format(hip_local)
    msg += "HIP (farm):  {}\n".format(hip_farm)
    msg += "Output Driver: {}\n".format(output_driver_path)
    msg += "Target Source: {}\n".format(target_source)
    if output_usd_local:
        msg += "USD Output (local): {}\n".format(output_usd_local)
        msg += "USD Output (farm):  {}\n".format(output_usd_farm)

    _show(msg)


def set_target_from_selection(kwargs):
    """
    Optional helper for a UI button:
      kwargs["node"].hdaModule().set_target_from_selection(kwargs)

    Writes first selected node path into parm 'target_lop_path'.
    """
    node = kwargs["node"]
    parm = node.parm("target_lop_path")
    if parm is None:
        _show("Parm 'target_lop_path' fehlt auf dem HDA.", severity=hou.severityType.Error)
        return

    selected = hou.selectedNodes()
    if not selected:
        _show("Kein Node selektiert.", severity=hou.severityType.Warning)
        return

    parm.set(selected[0].path())
