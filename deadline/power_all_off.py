#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
from Deadline.Scripting import RepositoryUtils

def __main__(*args):
    options = RepositoryUtils.GetPowerManagementOptions()
    for group in options.Groups:
        group.Enabled = False
        print("Disabled: " + group.Name)
    RepositoryUtils.SavePowerManagementOptions(options)
    print("ALL Power Management DISABLED")
