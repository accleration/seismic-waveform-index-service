import os
import argparse
import re

def get_subfolder_names(year):
    """
    获取指定年份的路径下所有合法的文件夹名称，并生成对应的 shell 命令列表。

    :param year: 指定的年份（如 2024）
    :return: (命令字符串列表, 年份后两位字符串)
    """
    base_path = f"/mnt/mseedindex_share/seisdata/{year}"
    year_suffix = str(year)[-2:]  # 获取年份后两位

    # 获取 base_path 下的所有子文件夹名称
    subfolders = []
    for folder in os.listdir(base_path):
        folder_path = os.path.join(base_path, folder)
        if not os.path.isdir(folder_path):
            continue

        try:
            # 尝试对文件夹名称进行编码，捕获异常的文件夹直接跳过
            folder.encode('utf-8')
        except Exception as e:
            # 对文件夹名称进行安全转换，防止打印时再次出错
            folder_safe = folder.encode('utf-8', errors='replace').decode('utf-8')
            print(f"跳过无法编码的目录: '{folder_safe}', 错误：{e}")
            continue

        # 只允许字母命名的文件夹
        if not re.match(r"^[A-Za-z]+$", folder):
            print(f"跳过包含非字母字符的目录: '{folder}'")
            continue

        subfolders.append(folder)

    # 生成 shell 命令列表，每个命令将对应目录下的文件路径写入不同文件
    result_strings = [
        f"find {base_path}/{folder}/ -type f > ./inputfile_list_{folder}_{year_suffix}"
        for folder in subfolders
    ]
    return result_strings, year_suffix

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="根据指定年份生成 shell 命令，并将结果保存到文件。")
    parser.add_argument("year", type=int, help="指定的年份，例如 2024")
    args = parser.parse_args()

    filled_strings, year_suffix = get_subfolder_names(args.year)

    # 定义输出文件名，格式为 inputfile_list_后两位（如 inputfile_list_24）
    output_filename = f"inputfile_list_{year_suffix}"

    try:
        with open(output_filename, "w", encoding="utf-8", errors="replace") as outfile:
            for cmd in filled_strings:
                outfile.write(cmd + "\n")
        print(f"结果已保存到文件 {output_filename}")
    except Exception as e:
        print(f"保存文件时发生错误：{e}")
