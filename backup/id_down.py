from Bio import Entrez
import time
import sys

Entrez.email = "496276044@qq.com"

##正确的汉坦病毒科 Taxonomy ID: 1980413
query = "txid1980413[Organism]"
print("正在检索 NCBI Hantaviridae 蛋白...")

#1. 获取所有蛋白 ID 列表
try:
    handle = Entrez.esearch(db="protein", term=query, retmax=50000)
    record = Entrez.read(handle)
    handle.close()
except Exception as e:
    print(f"检索失败: {e}")
    sys.exit(1)

id_list = record["IdList"]
total_count = int(record["Count"])
print(f"在 Protein 数据库中检索到 {total_count} 条记录。")

#2. 分批下载序列并写入文件
output_file = "/home/ubuntu/project/hanta_raw.faa"
batch_size = 300  # 适当减小 batch_size，防止请求超时

print("开始下载序列...")
with open(output_file, "w") as out_f:
    for i in range(0, len(id_list), batch_size):
        batch_ids = id_list[i:i+batch_size]
        attempt = 1
        while attempt <= 5:
            try:
                fetch_handle = Entrez.efetch(
                    db="protein", 
                    id=batch_ids, 
                    rettype="fasta", 
                    retmode="text",
                    timeout=30
                )
                data = fetch_handle.read()
                out_f.write(data)
                fetch_handle.close()
                print(f"已成功下载 {min(i + batch_size, len(id_list))} / {len(id_list)}")
                break
            except Exception as e:
                print(f"第 {attempt} 次下载失败 (第 {i} 到 {i+batch_size} 条): {e}. 正在重试...")
                time.sleep(3)
                attempt += 1
        else:
            print("连续5次下载失败，程序终止。请重新运行。")
            sys.exit(1)

print(f"全部下载完成！已保存至: {output_file}")