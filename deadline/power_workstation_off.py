#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
from Deadline.Scripting import RepositoryUtils

WORKSTATION_GROUPS = ["workstation"]

def __main__(*args):
    options = RepositoryUtils.GetPowerManagementOptions()
    for group in options.Groups:
        if group.Name in WORKSTATION_GROUPS:
            group.Enabled = False
            print("Disabled: " + group.Name)
    RepositoryUtils.SavePowerManagementOptions(options)
    print("Workstation Power Management DISABLED")
