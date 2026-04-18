#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
from Deadline.Scripting import RepositoryUtils

FARM_GROUPS    = ["farm"]
WORKSTATION_GROUPS = ["workstation"]

def __main__(*args):
    options = RepositoryUtils.GetPowerManagementOptions()
    farm_enabled = any(g.Enabled for g in options.Groups if g.Name in FARM_GROUPS)
    ws_enabled   = any(g.Enabled for g in options.Groups if g.Name in WORKSTATION_GROUPS)
    farm_str = "ENABLED" if farm_enabled else "DISABLED"
    ws_str   = "ENABLED" if ws_enabled   else "DISABLED"
    print(farm_str + "|" + ws_str)