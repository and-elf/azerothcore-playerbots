# install chocolatey before

# powershell.exe -NoProfile -InputFormat None -ExecutionPolicy Bypass -Command "iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))" && SET "PATH=%PATH%;%ALLUSERSPROFILE%\chocolatey\bin"

# install automatically following packages:
# cmake
# git
# microsoft-build-tools
# mysql

INSTALL_ARGS=()

if [[ $CONTINUOUS_INTEGRATION ]]; then
    INSTALL_ARGS+=(--no-progress)
else
    { # try
        choco uninstall -y -n cmake.install cmake # needed to make sure that following install set the env properly
    } || { # catch
        echo "nothing to do"
    }

    choco install -y --skip-checksums "${INSTALL_ARGS[@]}"  git visualstudio2022community
fi

choco install -y --skip-checksums "${INSTALL_ARGS[@]}"  cmake.install -y --installargs 'ADD_CMAKE_TO_PATH=System'
choco install -y --skip-checksums "${INSTALL_ARGS[@]}"  visualstudio2022-workload-nativedesktop
choco install -y --skip-checksums "${INSTALL_ARGS[@]}"  openssl --force
choco install -y --skip-checksums "${INSTALL_ARGS[@]}"  boost-msvc-14.3 --force --version=1.87.0
# MySQL: prefer the runner's preinstalled MySQL over the choco package. The choco
# `mysql` package downloads its zip from Oracle's CDN, which keeps only the current
# GA of each series, so any pinned version eventually 404s. GitHub's windows-2022
# image ships MySQL (server install with include/ and lib/) under
# "C:\Program Files\MySQL\MySQL Server X.Y"; junction it to the fixed, space-free
# path the build expects (C:\tools\mysql\current) so no build flags need to change.
MYSQL_HOME=$(ls -d "/c/Program Files/MySQL/MySQL Server "*/ 2>/dev/null | sort -V | tail -1)
if [[ -n "$MYSQL_HOME" && -f "${MYSQL_HOME}lib/mysqlclient.lib" ]]; then
    echo "Using preinstalled MySQL at: ${MYSQL_HOME}"
    mkdir -p /c/tools/mysql
    rm -rf "/c/tools/mysql/current"
    # Use PowerShell for the junction: Git Bash/MSYS mangles cmd's mklink switches
    # (/J, //c) into paths. MSYS_NO_PATHCONV keeps the backslash args intact.
    MSYS_NO_PATHCONV=1 powershell -NoProfile -Command \
        "New-Item -ItemType Junction -Path 'C:\\tools\\mysql\\current' -Target '$(cygpath -w "${MYSQL_HOME%/}")' | Out-Null"
else
    echo "No usable preinstalled MySQL found; falling back to the choco package."
    choco install -y --skip-checksums "${INSTALL_ARGS[@]}"  mysql --force
fi
