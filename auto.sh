#!/bin/bash

# 检查参数数量
if [ $# -ne 2 ]; then
    echo "用法: $0 <起始年份> <结束年份>"
    echo "示例: $0 2021 2025"
    exit 1
fi

start_year=$1
end_year=$2

# ==================== 用户可配置区（可用环境变量覆盖） ====================
SEISDATA_BASE="${SEISDATA_BASE:-/data/seisdata}"                                  # miniSEED 数据根目录，下含 <year>/<province>/...
INDEX_PROJECT_DIR="${INDEX_PROJECT_DIR:-$HOME/project/seismic-waveform-index}"      # 本脚本运行目录（生成年份 sqlite 与 All_Merged.sqlite）
MSEEDINDEX_BIN="${MSEEDINDEX_BIN:-$HOME/project/mseedindex-main/mseedindex}"        # mseedindex 可执行文件
FDSNWS_CONFIG="${FDSNWS_CONFIG:-$HOME/project/fdsnws_dataselect/server.ini}"        # fdsnws_dataselect 服务配置文件
CONDA_ROOT="${CONDA_ROOT:-$HOME/anaconda3}"                                         # Conda 根目录
CONDA_ENV_NAME="${CONDA_ENV_NAME:-seismic_env}"                                     # Conda 环境名
CONDA_ENV_BIN="${CONDA_ROOT}/envs/${CONDA_ENV_NAME}/bin"                            # Conda 环境 bin 目录
FINAL_SQLITE_PATH="${FINAL_SQLITE_PATH:-${INDEX_PROJECT_DIR}/All_Merged.sqlite}"    # 最终全量索引库路径
export SEISDATA_BASE
# =============================================================================

for (( year=$start_year; year<=$end_year; year++ ))
do
    echo "正在处理年份: $year"

    # 执行 Python 脚本，生成 inputfile_list 文件
    python get_subfolder_names_mseed.py "$year"

    # 年份后两位（如 23）
    year_suffix=${year:2:2}
    cmd_file="inputfile_list_${year_suffix}"

    if [ -f "$cmd_file" ]; then
        echo "已生成命令文件: $cmd_file"

        # 执行 find 命令生成 inputfile_list_* 省份文件
        while IFS= read -r line
        do
            echo "执行命令: $line"
            eval "$line"
        done < "$cmd_file"

        echo "年份 $year 的命令执行完成"

        # 创建年份目录并移动 inputfile_list_* 文件
        output_dir="./$year"
        mkdir -p "$output_dir"
        mv inputfile_list_*_"$year_suffix" "$output_dir"/
        echo "所有 inputfile_list_*_${year_suffix} 文件已移动至 $output_dir"

        # 进入年份目录
        cd "$output_dir" || continue

        echo "生成自动执行脚本: auto_mseedindex_shell_${year}"

        mkdir -p log
        mkdir -p sqlite_"${year}"
        > "auto_mseedindex_shell_${year}"  # 清空脚本文件

        # 生成 shell 执行语句（同步版本）
        for file in inputfile_list_*_"$year_suffix"; do
            province=$(echo "$file" | sed -E "s/inputfile_list_(.*)_${year_suffix}/\1/")
            echo "${MSEEDINDEX_BIN} -snd -sqlite ${year}_${province}_All.sqlite @$file > ./log/output_${province}_${year_suffix}.log 2>&1" >> "auto_mseedindex_shell_${year}"
        done

        chmod +x "auto_mseedindex_shell_${year}"
        echo "脚本 auto_mseedindex_shell_${year} 已生成完成"

        # 逐条同步执行脚本中的每个命令
        echo "开始同步执行 auto_mseedindex_shell_${year} 中的任务..."
        while IFS= read -r cmd; do
            echo "执行: $cmd"
            eval "$cmd"
        done < "auto_mseedindex_shell_${year}"
        echo "全部任务完成"

        # 移动所有生成的 .sqlite 文件
        mv ./*.sqlite sqlite_"${year}"/
        echo "所有 .sqlite 文件已移动到 sqlite_${year}/"

        cd ..

        # 合并所有 .sqlite 到一个年度数据库中
        echo "正在合并 sqlite_${year}/*.sqlite 到 ${year}_Merged.sqlite ..."
        python merge_sqlite_year.py ./${output_dir}/sqlite_${year} ./${output_dir}/${year}_Merged.sqlite
        echo "合并完成：${year}_Merged.sqlite"

        echo "------------------------------------"
    else
        echo "未找到命令文件: $cmd_file，跳过 $year"
    fi
done
echo "所有年份处理完成。"

# =============== 最终合并所有年度 .sqlite 到 All_Merged.sqlite ===============
# 创建临时目录用于合并
mkdir -p all_years_sqlite_temp

for (( year=$start_year; year<=$end_year; year++ ))
do
    merged_file="./$year/${year}_Merged.sqlite"
    if [ -f "$merged_file" ]; then
        cp "$merged_file" ./all_years_sqlite_temp/
        echo "复制 $merged_file 到临时目录"
    else
        echo "未找到 $merged_file，跳过"
    fi
done

rm -f ./All_Merged.sqlite
# 执行合并
echo "正在合并所有年度 Merged.sqlite 到 All_Merged.sqlite..."
python merge_sqlite_year.py ./all_years_sqlite_temp ./All_Merged.sqlite
echo "所有年度数据库已合并为 All_Merged.sqlite"

# 可选：清理中间目录
rm -r ./all_years_sqlite_temp

# 修改 fdsnws_dataselect 程序的配置文件（CONFIG_FILE / FINAL_SQLITE_PATH 已在文件顶部配置区定义）

if [ -f "$CONFIG_FILE" ]; then
    echo "正在更新 server.ini 中 [index_db] 段的 path 配置为：$FINAL_SQLITE_PATH"

    awk -v newpath="$FINAL_SQLITE_PATH" '
    BEGIN { section = ""; updated = 0 }
    /^\[.*\]/ { section = $0 }
    section == "[index_db]" && $1 ~ /^path$/ {
        print "path = " newpath; updated = 1; next
    }
    { print }
    END {
        if (!updated) {
            print "警告：未找到 [index_db] 段中的 path 设置。"
        }
    }
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    echo "server.ini 已更新完毕"
else
    echo "配置文件未找到：$CONFIG_FILE"
fi

# 运行fdsnws_dataselect程序
echo "准备启动 FDSNWS 数据服务..."

# 切换 Conda 环境并进入可执行目录（注意使用 bash -c 保证环境激活）
source "${CONDA_ROOT}/etc/profile.d/conda.sh"
conda activate "$CONDA_ENV_NAME"

# 切换到程序目录并启动服务
cd "${CONDA_ENV_BIN}" || {
    echo "无法进入可执行目录 ${CONDA_ENV_BIN}"
    exit 1
}

echo "正在检查是否已有 portable-fdsnws-dataselect 实例运行..."
# 查找相关进程（排除 grep 自身），提取 PID 并逐个 kill
pids=$(ps -aux | grep portable-fdsnws-dataselect | grep -v grep | awk '{print $2}')
if [ -n "$pids" ]; then
    echo "发现以下 portable-fdsnws-dataselect 进程，将全部终止："
    echo "$pids"
    kill -9 $pids
    echo "所有旧的 portable-fdsnws-dataselect 实例已终止。"
else
    echo "没有运行中的 portable-fdsnws-dataselect 实例。"
fi

# 启动服务
echo "启动 portable-fdsnws-dataselect 服务..."
nohup ./portable-fdsnws-dataselect "$FDSNWS_CONFIG" > server.log 2>&1 &

echo "FDSNWS 服务已后台运行，日志输出：server.log"

