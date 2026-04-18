#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
# farm - LOCAL SECRETS (TEMPLATE)
# Copy this file to secrets.py and fill in your values.
# secrets.py is excluded from version control via .gitignore.

# Path mapping: local workstation prefix -> farm Linux prefix
# Example: files under /Users/you/MyProject/ are accessible
#          on the farm at /mnt/
PATH_MAP = {
    "/Users/youruser/YourProject/": "/mnt/",
}
