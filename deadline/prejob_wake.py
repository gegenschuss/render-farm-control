#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
import os
from System.Diagnostics import Process, ProcessStartInfo


DEFAULT_WAKE_SCRIPT = "/mnt/studio/Toolbox/farm/scripts/core/wake.sh"
DEFAULT_PREJOB_WAIT_SECONDS = 45


def _shell_quote(text):
    text = str(text)
    return "'" + text.replace("'", "'\"'\"'") + "'"


def _run_bash_command(argv):
    psi = ProcessStartInfo()
    psi.FileName = "/bin/bash"
    psi.Arguments = " ".join([_shell_quote(arg) for arg in argv])
    psi.UseShellExecute = False
    psi.RedirectStandardOutput = True
    psi.RedirectStandardError = True
    psi.CreateNoWindow = True

    proc = Process()
    proc.StartInfo = psi
    proc.Start()
    stdout_text = proc.StandardOutput.ReadToEnd()
    stderr_text = proc.StandardError.ReadToEnd()
    proc.WaitForExit()

    output = stdout_text
    if stderr_text:
        output = output + ("\n" if output else "") + stderr_text
    return proc.ExitCode, output


def _truthy_env(name, default=False):
    raw = os.environ.get(name, "")
    if not raw:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _int_env(name, default_value, min_value):
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default_value
    try:
        value = int(raw)
    except Exception:
        return default_value
    if value < min_value:
        return min_value
    return value


def _log_info(plugin, message):
    if plugin is not None and hasattr(plugin, "LogInfo"):
        plugin.LogInfo(message)
    else:
        print(message)


def _log_warning(plugin, message):
    if plugin is not None and hasattr(plugin, "LogWarning"):
        plugin.LogWarning(message)
    else:
        print("WARNING: {0}".format(message))


def _fail(plugin, message):
    if plugin is not None and hasattr(plugin, "FailRender"):
        plugin.FailRender(message)
    raise Exception(message)


def __main__(*args):
    deadline_plugin = args[0] if len(args) > 0 else None

    wake_script = os.environ.get("FARM_WAKE_SCRIPT", DEFAULT_WAKE_SCRIPT).strip()
    if not wake_script:
        wake_script = DEFAULT_WAKE_SCRIPT

    wait_seconds = _int_env(
        "FARM_WAKE_PREJOB_WAIT",
        DEFAULT_PREJOB_WAIT_SECONDS,
        5,
    )
    strict_mode = _truthy_env("FARM_WAKE_PREJOB_STRICT", False)

    wake_mode_flag = "--silent-strict" if strict_mode else "--silent"
    cmd = [
        wake_script,
        wake_mode_flag,
        "--prejob-wait={0}".format(wait_seconds),
    ]

    _log_info(
        deadline_plugin,
        "FarmPreJobWake: running {0}".format(
            " ".join([_shell_quote(arg) for arg in cmd])
        ),
    )

    exit_code, output = _run_bash_command(cmd)
    if output:
        _log_info(deadline_plugin, "FarmPreJobWake output:\n{0}".format(output.rstrip()))

    if exit_code != 0:
        _fail(
            deadline_plugin,
            "FarmPreJobWake failed (exit={0}).".format(exit_code),
        )

    _log_info(deadline_plugin, "FarmPreJobWake succeeded.")
