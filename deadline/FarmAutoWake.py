#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
from Deadline.Events import DeadlineEventListener
from Deadline.Scripting import RepositoryUtils
from System.Diagnostics import Process, ProcessStartInfo
import time


def GetDeadlineEventListener():
    return FarmAutoWake()


def CleanupDeadlineEventListener(deadlinePlugin):
    deadlinePlugin.Cleanup()


class FarmAutoWake(DeadlineEventListener):
    META_LAST_SUBMIT_EPOCH = "farmautowake.last_submit_epoch"

    def __init__(self):
        super(FarmAutoWake, self).__init__()
        self.OnHouseCleaningCallback += self.OnHouseCleaning

    def Cleanup(self):
        del self.OnHouseCleaningCallback

    def OnHouseCleaning(self):
        try:
            interval_minutes = self.GetIntegerConfigEntryWithDefault("IntervalMinutes", 10)
            if interval_minutes < 1:
                interval_minutes = 1

            wake_submit_script = self.GetConfigEntryWithDefault(
                "WakeSubmitScript",
                "/mnt/studio/Toolbox/farm/scripts/deadline/submit.sh",
            ).strip()
            wake_script = self.GetConfigEntryWithDefault(
                "WakeScript",
                "",
            ).strip()
            wake_allow_list = self.GetConfigEntryWithDefault(
                "WakeWorkerWhitelist",
                "",
            ).strip()
            wake_prejob_wait = self.GetIntegerConfigEntryWithDefault("WakePrejobWaitSeconds", 45)
            if wake_prejob_wait < 5:
                wake_prejob_wait = 5

            wake_name_prefix = self.GetConfigEntryWithDefault(
                "WakeJobNamePrefix",
                "Farm Auto Wake Tick",
            ).strip()
            if not wake_name_prefix:
                wake_name_prefix = "Farm Auto Wake Tick"

            dry_run = self.GetBooleanConfigEntryWithDefault("DryRun", False)

            now_epoch = int(time.time())
            last_epoch = self._get_last_submit_epoch()
            if last_epoch > 0 and (now_epoch - last_epoch) < (interval_minutes * 60):
                return

            active_jobs = RepositoryUtils.GetJobsInState("Active")
            active_render_jobs = []
            existing_wake_jobs = []

            for job in active_jobs:
                plugin_name = (job.JobPlugin or "").strip()
                job_name = (job.JobName or "").strip()

                if plugin_name == "CommandScript" and job_name.startswith(wake_name_prefix):
                    existing_wake_jobs.append(job)
                    continue

                active_render_jobs.append(job)

            if len(active_render_jobs) == 0:
                return

            if len(existing_wake_jobs) > 0:
                self.LogInfo(
                    "FarmAutoWake: wake job already active (count={0}); skipping submit.".format(
                        len(existing_wake_jobs)
                    )
                )
                self._set_last_submit_epoch(now_epoch)
                return

            wake_job_name = "{0} {1}".format(
                wake_name_prefix,
                time.strftime("%Y-%m-%d %H:%M:%S"),
            )

            submit_args = [
                wake_submit_script,
                "--no-header",
                "--name",
                wake_job_name,
                "--allow-list",
                wake_allow_list,
                "--script",
                wake_script,
                "--",
                "--silent",
                "--prejob-wait={0}".format(wake_prejob_wait),
            ]

            if dry_run:
                self.LogInfo(
                    "FarmAutoWake [dry-run]: would submit wake job: {0}".format(
                        " ".join([self._shell_quote(arg) for arg in submit_args])
                    )
                )
                self._set_last_submit_epoch(now_epoch)
                return

            exit_code, output = self._run_bash_command(submit_args)
            if output:
                self.LogInfo("FarmAutoWake submit output:\n{0}".format(output.rstrip()))

            if exit_code == 0:
                self._set_last_submit_epoch(now_epoch)
                self.LogInfo(
                    "FarmAutoWake: wake submit succeeded for {0} active job(s).".format(
                        len(active_render_jobs)
                    )
                )
            else:
                self.LogWarning(
                    "FarmAutoWake: wake submit failed (exit={0}).".format(exit_code)
                )

        except Exception:
            self.LogWarning(self.GetTraceback())

    def _run_bash_command(self, argv):
        psi = ProcessStartInfo()
        psi.FileName = "/bin/bash"
        psi.Arguments = " ".join([self._shell_quote(arg) for arg in argv])
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

    def _get_last_submit_epoch(self):
        try:
            value = self.GetMetaDataEntry(self.META_LAST_SUBMIT_EPOCH)
            if not value:
                return 0
            return int(value)
        except Exception:
            return 0

    def _set_last_submit_epoch(self, epoch_value):
        value = str(int(epoch_value))
        try:
            existing = self.GetMetaDataEntry(self.META_LAST_SUBMIT_EPOCH)
            if existing:
                self.UpdateMetaDataEntry(self.META_LAST_SUBMIT_EPOCH, value)
            else:
                self.AddMetaDataEntry(self.META_LAST_SUBMIT_EPOCH, value)
        except Exception:
            try:
                self.AddMetaDataEntry(self.META_LAST_SUBMIT_EPOCH, value)
            except Exception:
                self.UpdateMetaDataEntry(self.META_LAST_SUBMIT_EPOCH, value)

    def _shell_quote(self, text):
        text = str(text)
        return "'" + text.replace("'", "'\"'\"'") + "'"
