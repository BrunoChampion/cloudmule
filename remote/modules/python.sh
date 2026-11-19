# module: python — Python 3 venv + numpy from Ubuntu (enough for analysis / media scripts).
# For other versions or packages, use a venv or uv in the project's server-setup.sh / INSTALL_CMD.
# arch: x86 arm
# apt: python3-numpy python3-venv
python3 -c "import numpy; print('numpy', numpy.__version__)"
