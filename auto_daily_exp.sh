#!/bin/bash
set -e

# =====================================================
#               用户可配置区（只改这里）
# =====================================================

# 用户 home 目录
USER_HOME="${USER_HOME:-$HOME}"

# MiniSEED 数据根目录
SEISDATA_BASE="${SEISDATA_BASE:-/data/seisdata}"

# mseedindex 项目目录
MSEEDINDEX_DIR="${MSEEDINDEX_DIR:-$USER_HOME/project/mseedindex-main}"

# 索引工程目录（本脚本运行目录）
INDEX_PROJECT_DIR="${INDEX_PROJECT_DIR:-$USER_HOME/project/seismic-waveform-index}"

# fdsnws_dataselect 工程目录
FDSNWS_PROJECT_DIR="${FDSNWS_PROJECT_DIR:-$USER_HOME/project/fdsnws_dataselect}"

# Conda 根目录与环境
CONDA_ROOT="${CONDA_ROOT:-$USER_HOME/anaconda3}"
CONDA_ENV_NAME="${CONDA_ENV_NAME:-seismic_env}"

# 起始年份（用于全库合并）
START_YEAR=2021

export SEISDATA_BASE

# =====================================================
#               派生变量（勿改）
# =====================================================

YEAR=$(date +%Y)
TODAY=$(date '+%F %T')

DATA_DIR="${SEISDATA_BASE}/${YEAR}"
LOG_DIR="${INDEX_PROJECT_DIR}/logs"
STAMP_DIR="${INDEX_PROJECT_DIR}/stamps"

MERGED_DB="${INDEX_PROJECT_DIR}/${YEAR}/${YEAR}_Merged.sqlite"
OUTPUT_DB="${INDEX_PROJECT_DIR}/All_Merged_Daily.sqlite"

TMP_DB="timeseries.sqlite"
TMP_MERGE_DIR="${INDEX_PROJECT_DIR}/tmp_merge_all"

LOG_FILE="${LOG_DIR}/incremental_index_${YEAR}.log"

FDSNWS_BIN_DIR="${CONDA_ROOT}/envs/${CONDA_ENV_NAME}/bin"
FDSNWS_CONFIG="${FDSNWS_PROJECT_DIR}/server_daily.ini"

SQLITE3_BIN="${CONDA_ROOT}/bin/sqlite3"
MSEEDINDEX_BIN="${MSEEDINDEX_DIR}/mseedindex"

# =====================================================
#               环境准备
# =====================================================

source "${USER_HOME}/.bashrc" || true
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

mkdir -p "$LOG_DIR" "$STAMP_DIR"

cd "$INDEX_PROJECT_DIR" || {
    echo "无法进入工作目录：$INDEX_PROJECT_DIR" | tee -a "$LOG_FILE"
    exit 1
}

echo "========= $TODAY 开始智能增量索引任务 =========" >> "$LOG_FILE"

# =====================================================
#        年度首次索引构建
# =====================================================

if [ ! -f "$MERGED_DB" ]; then
    echo "【年度首次】$YEAR 年索引库不存在，开始构建" | tee -a "$LOG_FILE"

    YEAR_DIR="$(dirname "$MERGED_DB")"
    mkdir -p "$YEAR_DIR"
    cd "$YEAR_DIR" || {
        echo "错误：无法进入年度目录 $YEAR_DIR" | tee -a "$LOG_FILE"
        exit 1
    }

    # ---------- 1. 生成 inputfile_list ----------
    if ! python3 "${INDEX_PROJECT_DIR}/get_subfolder_names_mseed.py" "$YEAR" >> "$LOG_FILE" 2>&1; then
        echo "错误：get_subfolder_names_mseed.py 执行失败" | tee -a "$LOG_FILE"
        exit 1
    fi

    year_suffix=${YEAR:2:2}
    cmd_file="inputfile_list_${year_suffix}"

    if [ ! -s "$cmd_file" ]; then
        echo "错误：未生成有效的 $cmd_file" | tee -a "$LOG_FILE"
        exit 1
    fi

    # ---------- 2. 执行 find，生成省份文件 ----------
    while IFS= read -r line; do
        if ! eval "$line"; then
            echo "错误：执行命令失败：$line" | tee -a "$LOG_FILE"
            exit 1
        fi
    done < "$cmd_file"

    mkdir -p log "sqlite_${YEAR}"
    > "auto_mseedindex_shell_${YEAR}"

    # ---------- 3. 省级 sqlite 构建 ----------
    SQLITE_OK=true

    for file in inputfile_list_*_"$year_suffix"; do
        province=$(echo "$file" | sed -E "s/inputfile_list_(.*)_${year_suffix}/\1/")
        cmd="${MSEEDINDEX_BIN} -snd -sqlite ${YEAR}_${province}_All.sqlite @$file \
            > ./log/output_${province}_${year_suffix}.log 2>&1"

        if ! eval "$cmd"; then
            echo "错误：省份 $province 索引构建失败" | tee -a "$LOG_FILE"
            SQLITE_OK=false
            break
        fi
    done

    if [ "$SQLITE_OK" != true ]; then
        echo "【年度首次失败】省级 sqlite 构建未完成，终止流程" | tee -a "$LOG_FILE"
        exit 1
    fi

    mv ./*.sqlite "sqlite_${YEAR}/" || {
        echo "错误：移动 sqlite 文件失败" | tee -a "$LOG_FILE"
        exit 1
    }

    # ---------- 4. 合并年度数据库 ----------
    if ! python3 "${INDEX_PROJECT_DIR}/merge_sqlite_year.py" \
        "sqlite_${YEAR}" "$MERGED_DB" >> "$LOG_FILE" 2>&1; then
        echo "错误：年度数据库合并失败" | tee -a "$LOG_FILE"
        exit 1
    fi

    # ---------- 5. 最终校验 ----------
    if [ ! -f "$MERGED_DB" ]; then
        echo "致命错误：年度数据库文件未生成：$MERGED_DB" | tee -a "$LOG_FILE"
        exit 1
    fi

    COUNT=$("$SQLITE3_BIN" "$MERGED_DB" "SELECT COUNT(*) FROM tsindex;")
    if [ "$COUNT" -eq 0 ]; then
        echo "致命错误：年度数据库为空（tsindex=0）" | tee -a "$LOG_FILE"
        exit 1
    fi

    echo "【年度首次成功】$YEAR 年索引库构建完成，记录数：$COUNT" | tee -a "$LOG_FILE"
fi

# =====================================================
#        读取数据库最后索引时间
# =====================================================

DB_LAST_TIME=$("$SQLITE3_BIN" "$MERGED_DB" "SELECT MAX(endtime) FROM tsindex;")

if [ -z "$DB_LAST_TIME" ]; then
    echo "错误：数据库中无 tsindex 记录" | tee -a "$LOG_FILE"
    exit 1
fi

echo "数据库最后更新时间：$DB_LAST_TIME" >> "$LOG_FILE"

# =====================================================
#        构建时间戳参考文件
# =====================================================

REF_FILE=".last_timestamp_tmp"
rm -f "$REF_FILE"
touch -d "$DB_LAST_TIME" "$REF_FILE"

# =====================================================
#        查找新增 mseed 文件
# =====================================================

rm -f mseed_increment_list.txt
find "$DATA_DIR" -type f -newer "$REF_FILE" > mseed_increment_list.txt
rm -f "$REF_FILE"

if [ ! -s mseed_increment_list.txt ]; then
    echo "无新增文件，任务结束。" >> "$LOG_FILE"
    exit 0
fi

# =====================================================
#        增量建立临时索引
# =====================================================

echo "开始建立临时索引库..." >> "$LOG_FILE"

"$MSEEDINDEX_BIN" -snd -sqlite "$TMP_DB" @mseed_increment_list.txt >> "$LOG_FILE" 2>&1

if [ ! -f "$TMP_DB" ]; then
    echo "错误：临时索引数据库创建失败" >> "$LOG_FILE"
    exit 1
fi

# =====================================================
#        合并到年度数据库
# =====================================================

echo "合并索引至年度数据库..." >> "$LOG_FILE"

"$SQLITE3_BIN" "$MERGED_DB" <<EOF >> "$LOG_FILE" 2>&1
ATTACH DATABASE '$TMP_DB' AS newdb;
INSERT OR IGNORE INTO tsindex SELECT * FROM newdb.tsindex;
DETACH DATABASE newdb;
EOF

rm -f "$TMP_DB" mseed_increment_list.txt

echo "年度索引合并完成：$(date '+%F %T')" >> "$LOG_FILE"

# =====================================================
#        合并所有年度数据库
# =====================================================

echo "========= 开始合并所有年度数据库 =========" >> "$LOG_FILE"

mkdir -p "$TMP_MERGE_DIR"
rm -f "$TMP_MERGE_DIR"/*.sqlite

for Y in $(seq "$START_YEAR" "$YEAR"); do
    YDB="${INDEX_PROJECT_DIR}/${Y}/${Y}_Merged.sqlite"
    if [ -f "$YDB" ]; then
        cp "$YDB" "$TMP_MERGE_DIR/"
        echo "已加入年度数据库：$YDB" >> "$LOG_FILE"
    else
        echo "警告：缺失年度数据库 $YDB" >> "$LOG_FILE"
    fi
done

rm -f "$OUTPUT_DB"

python3 "${INDEX_PROJECT_DIR}/merge_sqlite_year.py" "$TMP_MERGE_DIR" "$OUTPUT_DB" >> "$LOG_FILE" 2>&1

rm -rf "$TMP_MERGE_DIR"

echo "全量数据库生成完成：$OUTPUT_DB" >> "$LOG_FILE"

echo "开始为 All_Merged_Daily.sqlite 建立查询索引" >> "$LOG_FILE"
"$SQLITE3_BIN" "$OUTPUT_DB" <<EOF >> "$LOG_FILE" 2>&1
CREATE INDEX IF NOT EXISTS idx_tsindex_nslc_time
ON tsindex (
    network,
    station,
    location,
    channel,
    starttime,
    endtime
);
ANALYZE;
EOF
echo "索引与统计信息更新完成" >> "$LOG_FILE"

# =====================================================
#        更新 FDSNWS 配置文件
# =====================================================

awk -v newpath="$OUTPUT_DB" '
BEGIN { section = ""; updated = 0 }
/^\[.*\]/ { section = $0 }
section == "[index_db]" && $1 ~ /^path$/ {
    print "path = " newpath; updated = 1; next
}
{ print }
END {
    if (!updated) {
        print "path = " newpath
    }
}
' "$FDSNWS_CONFIG" > "${FDSNWS_CONFIG}.tmp" && mv "${FDSNWS_CONFIG}.tmp" "$FDSNWS_CONFIG"

echo "FDSNWS 配置已更新" >> "$LOG_FILE"

# =====================================================
#        重启 FDSNWS Dataselect 服务
# =====================================================

source "${CONDA_ROOT}/etc/profile.d/conda.sh"
conda activate "$CONDA_ENV_NAME"

cd "$FDSNWS_BIN_DIR" || exit 1

pids=$(ps -aux | grep portable-fdsnws-dataselect | grep -v grep | awk '{print $2}')
if [ -n "$pids" ]; then
    kill -9 $pids
    echo "旧 FDSNWS 服务已停止" >> "$LOG_FILE"
fi

nohup ./portable-fdsnws-dataselect "$FDSNWS_CONFIG" >> "$LOG_FILE" 2>&1 &

echo "FDSNWS 服务已启动" >> "$LOG_FILE"
echo "========= 全部任务完成 =========" >> "$LOG_FILE"
