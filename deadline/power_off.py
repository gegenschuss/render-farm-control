#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
from Deadline.Scripting import RepositoryUtils

# Groups to enable/disable with power management
FARM_GROUPS    = ["farm"]
WORKSTATION_GROUPS = ["workstation"]

def __main__(*args):
    options = RepositoryUtils.GetPowerManagementOptions()
    for group in options.Groups:
        if group.Name in FARM_GROUPS:
            group.Enabled = False
            print("Disabled: " + group.Name)
        elif group.Name in WORKSTATION_GROUPS:
            group.Enabled = False
            print("Skipped (workstation): " + group.Name)
        else:
            print("Ignored (unknown group): " + group.Name)
    RepositoryUtils.SavePowerManagementOptions(options)
    print("Farm Power Management DISABLED")