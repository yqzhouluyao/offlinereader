import Foundation

enum TransferWebPage {
    static func html(token: String) -> String {
        """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>WiFi 传书</title>
          <style>
            :root {
              color-scheme: light;
              --blue-1: #2f66a9;
              --blue-2: #6393c4;
              --panel: #eef3f7;
              --header: #95abba;
              --line: #bdcad4;
              --row: #f5f7f9;
              --row-alt: #dbe2e8;
              --text: #17212b;
              --muted: #607589;
              --danger: #c9473b;
            }
            * { box-sizing: border-box; }
            html, body { margin: 0; min-height: 100%; }
            body {
              font-family: Tahoma, Arial, "PingFang SC", "Microsoft YaHei", sans-serif;
              font-size: 14px;
              color: var(--text);
              background:
                radial-gradient(circle at 12% 14%, rgba(255,255,255,0.28), transparent 30%),
                linear-gradient(180deg, var(--blue-2), var(--blue-1));
            }
            #wrapper {
              width: min(980px, calc(100vw - 40px));
              min-height: 760px;
              margin: 0 auto;
              display: grid;
              grid-template-columns: 290px 1fr;
              gap: 34px;
              align-items: start;
            }
            #left { min-height: 720px; padding-top: 74px; color: white; text-align: center; }
            #logo {
              width: 210px;
              height: 210px;
              margin: 0 auto 22px;
              border-radius: 32px;
              background:
                radial-gradient(circle at center 42%, rgba(255,255,255,0.96) 0 7px, transparent 8px),
                radial-gradient(circle at center 42%, transparent 0 34px, rgba(255,255,255,0.82) 35px 39px, transparent 40px),
                radial-gradient(circle at center 42%, transparent 0 66px, rgba(255,255,255,0.58) 67px 71px, transparent 72px),
                linear-gradient(180deg, rgba(255,255,255,0.22), rgba(255,255,255,0.08));
              border: 1px solid rgba(255,255,255,0.26);
              box-shadow: 0 20px 60px rgba(7,37,77,0.28), inset 0 1px 0 rgba(255,255,255,0.28);
              position: relative;
            }
            #logo::after {
              content: "OfflineReader";
              position: absolute;
              left: 0;
              right: 0;
              bottom: 32px;
              font-size: 18px;
              font-weight: 700;
              letter-spacing: 0;
            }
            #dragArea {
              width: 210px;
              height: 150px;
              margin: 0 auto 18px;
              border: 2px dashed rgba(255,255,255,0.64);
              border-radius: 16px;
              display: grid;
              place-items: center;
              color: white;
              font-size: 20px;
              font-weight: 700;
              text-shadow: 0 3px 8px rgba(0,0,0,0.22);
              background: rgba(255,255,255,0.08);
            }
            #dragArea.active {
              background: rgba(255,255,255,0.22);
              border-color: white;
            }
            #uploadForm { width: 244px; margin: 0 auto; position: relative; }
            #choose {
              width: 210px;
              height: 88px;
              border: 0;
              border-radius: 14px;
              color: white;
              cursor: pointer;
              background: linear-gradient(180deg, #6dc45f, #268b3f);
              box-shadow: inset 0 1px 0 rgba(255,255,255,0.35), 0 12px 24px rgba(0,0,0,0.22);
            }
            #choose strong { display: block; font-size: 20px; line-height: 26px; }
            #choose span { display: block; margin-top: 4px; font-size: 12px; opacity: 0.9; }
            #file { display: none; }
            #uploadHint { width: 244px; margin: 14px auto 0; color: rgba(255,255,255,0.9); line-height: 1.5; font-size: 12px; }
            #copyright { margin-top: 116px; color: rgba(255,255,255,0.76); }
            #rightWrapper {
              min-height: 100vh;
              padding: 0 0 42px;
              background: rgba(239,245,250,0.72);
              box-shadow: 0 0 40px rgba(16,52,92,0.18);
            }
            #right { width: 100%; }
            .contentTitle {
              height: 42px;
              line-height: 42px;
              padding: 0 14px;
              margin: 0 38px;
              color: white;
              background: linear-gradient(180deg, #a7bac8, var(--header));
              border-bottom: 1px solid #87a2b8;
              font-weight: 700;
            }
            .contentTitle span { margin-left: 10px; color: #ffd463; font-size: 12px; font-weight: 500; }
            .tableHeader, .fileRow {
              display: grid;
              grid-template-columns: minmax(180px, 1fr) 92px 118px;
              margin: 0 38px;
            }
            .tableHeader {
              height: 34px;
              line-height: 34px;
              color: var(--muted);
              background: #e4ebf0;
              border-bottom: 1px solid var(--line);
              font-size: 12px;
              font-weight: 700;
            }
            .tableHeader div, .fileRow div { padding: 0 10px; min-width: 0; }
            .tableHeader div + div, .fileRow div + div { border-left: 1px solid rgba(136,157,174,0.42); }
            #files {
              margin: 0 38px;
              max-height: calc(100vh - 76px);
              overflow: auto;
              background: var(--panel);
            }
            .fileRow {
              margin: 0;
              min-height: 40px;
              line-height: 40px;
              background: var(--row);
              border-bottom: 1px solid rgba(188,202,212,0.54);
              position: relative;
              overflow: hidden;
            }
            .fileRow:nth-child(even) { background: var(--row-alt); }
            .fileRow.progressRow { color: white; background: #5f89b2; }
            .progressBar {
              position: absolute;
              inset: 0 auto 0 0;
              width: 0%;
              background: linear-gradient(90deg, #4fab67, #78c968);
              z-index: 0;
              transition: width 160ms ease;
            }
            .fileRow > div { position: relative; z-index: 1; }
            .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            .size { color: var(--muted); }
            .progressRow .size { color: rgba(255,255,255,0.92); }
            .operate {
              display: flex;
              gap: 8px;
              align-items: center;
              justify-content: center;
            }
            .operate a, .operate button {
              appearance: none;
              border: 0;
              background: transparent;
              color: #2b649c;
              cursor: pointer;
              font: inherit;
              padding: 0 2px;
              text-decoration: none;
            }
            .operate button.delete { color: var(--danger); }
            .operate button.cancel { color: white; }
            .empty {
              margin: 0;
              padding: 44px 20px;
              text-align: center;
              color: var(--muted);
              background: var(--panel);
            }
            @media (max-width: 820px) {
              #wrapper { width: calc(100vw - 24px); grid-template-columns: 1fr; gap: 20px; }
              #left { min-height: 0; padding-top: 28px; }
              #copyright { display: none; }
              #rightWrapper { min-height: 360px; }
              .contentTitle, .tableHeader, #files { margin-left: 0; margin-right: 0; }
            }
          </style>
        </head>
        <body>
          <div id="wrapper">
            <section id="left">
              <div id="logo"></div>
              <div id="dragArea">拖拽到此处上传</div>
              <div id="uploadForm">
                <input id="file" type="file" accept="\(SupportedBookFormat.uploadAcceptAttribute)" multiple>
                <button id="choose" type="button"><strong>选择文件</strong><span>可同时上传多个文件</span></button>
                <div id="uploadHint">请选择您要上传的电子书文件<br>支持 EPUB、TXT 和 PDF</div>
              </div>
              <div id="copyright">OfflineReader WiFi Transfer</div>
            </section>
            <section id="rightWrapper">
              <div id="right">
                <div class="contentTitle">您设备上的文件列表<span id="status">等待上传</span></div>
                <div class="tableHeader">
                  <div>文件名</div>
                  <div>大小</div>
                  <div>操作</div>
                </div>
                <div id="files"></div>
              </div>
            </section>
          </div>
          <script>
            const token = "\(token)";
            const chunkSizeFallback = \(UploadSession.chunkSize);
            const supportedExtensions = new Set(["epub", "pdf", "txt"]);
            const dragArea = document.getElementById("dragArea");
            const input = document.getElementById("file");
            const choose = document.getElementById("choose");
            const filesContainer = document.getElementById("files");
            const status = document.getElementById("status");
            let isUploading = false;

            choose.onclick = () => input.click();
            input.onchange = () => {
              if (input.files.length) uploadFiles(Array.from(input.files));
              input.value = "";
            };
            dragArea.ondragover = event => {
              event.preventDefault();
              dragArea.classList.add("active");
            };
            dragArea.ondragleave = event => {
              event.preventDefault();
              dragArea.classList.remove("active");
            };
            dragArea.ondrop = event => {
              event.preventDefault();
              dragArea.classList.remove("active");
              if (event.dataTransfer.files.length) uploadFiles(Array.from(event.dataTransfer.files));
            };

            async function request(path, init = {}) {
              init.headers = Object.assign({"X-Transfer-Token": token}, init.headers || {});
              const response = await fetch(path, init);
              if (!response.ok) throw new Error(await response.text() || response.statusText);
              if (response.status === 204) return null;
              return await response.json();
            }

            function fileExtension(name) {
              const lower = name.toLowerCase();
              return lower.includes(".") ? lower.split(".").pop() : "";
            }

            function isSupportedBook(file) {
              return supportedExtensions.has(fileExtension(file.name));
            }

            function formatSize(bytes) {
              const units = ["B", "KB", "MB", "GB"];
              let value = Math.max(Number(bytes) || 0, 0);
              let index = 0;
              while (value >= 1024 && index < units.length - 1) {
                value /= 1024;
                index += 1;
              }
              return index === 0 ? `${Math.round(value)} ${units[index]}` : `${value.toFixed(1)} ${units[index]}`;
            }

            function makeCell(className, text) {
              const cell = document.createElement("div");
              cell.className = className;
              cell.textContent = text || "";
              return cell;
            }

            function makeRow(className) {
              const row = document.createElement("div");
              row.className = className || "fileRow";
              return row;
            }

            function setStatus(text) {
              status.textContent = text;
            }

            async function loadFileList() {
              try {
                const files = await request("/files");
                renderFileList(files || []);
              } catch (error) {
                setStatus("无法读取文件列表");
              }
            }

            function renderFileList(files) {
              filesContainer.innerHTML = "";
              if (!files.length) {
                const empty = document.createElement("div");
                empty.className = "empty";
                empty.textContent = "暂无文件";
                filesContainer.appendChild(empty);
                return;
              }
              files.forEach(file => filesContainer.appendChild(renderFileRow(file)));
            }

            function renderFileRow(file) {
              const row = makeRow("fileRow");
              row.appendChild(makeCell("name", file.name));
              row.appendChild(makeCell("size", file.size));
              const operate = makeCell("operate", "");

              const download = document.createElement("a");
              download.textContent = "下载";
              download.title = "下载文件";
              download.href = `/files/${file.id}/download?token=${encodeURIComponent(token)}`;
              operate.appendChild(download);

              const del = document.createElement("button");
              del.type = "button";
              del.className = "delete";
              del.textContent = "删除";
              del.title = "删除文件";
              del.onclick = () => deleteBook(file.id, row);
              operate.appendChild(del);

              row.appendChild(operate);
              return row;
            }

            async function deleteBook(id, row) {
              if (!confirm("是否删除图书？")) return;
              row.style.color = "white";
              row.style.background = "#cb4638";
              try {
                await request(`/files/${id}`, { method: "DELETE" });
                row.remove();
                if (!filesContainer.querySelector(".fileRow")) {
                  await loadFileList();
                }
                setStatus("已删除");
              } catch (error) {
                setStatus(`删除失败：${error.message}`);
                await loadFileList();
              }
            }

            function makeProgressRow(file, index, count) {
              const row = makeRow("fileRow progressRow");
              const bar = document.createElement("div");
              bar.className = "progressBar";
              row.appendChild(bar);
              row.appendChild(makeCell("name", file.name));
              row.appendChild(makeCell("size", formatSize(file.size)));
              const operate = makeCell("operate", "");
              const progress = document.createElement("span");
              progress.textContent = `0% (${index + 1}/${count})`;
              operate.appendChild(progress);
              row.appendChild(operate);
              filesContainer.prepend(row);
              return { row, bar, progress };
            }

            function updateProgress(progressRow, percent) {
              const value = Math.max(0, Math.min(100, Math.round(percent)));
              progressRow.bar.style.width = `${value}%`;
              progressRow.progress.textContent = `${value}%`;
            }

            async function uploadFiles(fileList) {
              if (isUploading) {
                setStatus("当前队列还在上传");
                return;
              }
              const files = fileList.filter(isSupportedBook);
              const skipped = fileList.length - files.length;
              if (!files.length) {
                alert("请选择 EPUB、TXT 或 PDF 图书文件。");
                return;
              }

              isUploading = true;
              choose.disabled = true;
              setStatus("正在上传");
              let succeeded = 0;
              let failed = 0;
              for (let i = 0; i < files.length; i += 1) {
                const file = files[i];
                const progressRow = makeProgressRow(file, i, files.length);
                try {
                  await uploadFile(file, i, files.length, progressRow);
                  succeeded += 1;
                } catch (error) {
                  failed += 1;
                  progressRow.row.style.background = "#cb4638";
                  progressRow.progress.textContent = "失败";
                }
              }
              choose.disabled = false;
              isUploading = false;
              await loadFileList();
              setStatus(failed === 0 ? `已上传 ${succeeded} 个文件` : `成功 ${succeeded} 个，失败 ${failed} 个`);
              if (skipped > 0) {
                setStatus(`${status.textContent}，跳过 ${skipped} 个不支持的文件`);
              }
            }

            async function uploadFile(file, fileIndex, fileCount, progressRow) {
              setStatus(`正在准备 ${file.name}`);
              const session = await request("/api/v1/uploads", {
                method: "POST",
                headers: {"Content-Type": "application/json"},
                body: JSON.stringify({fileName: file.name, fileSize: file.size})
              });
              const chunkSize = session.chunkSize || chunkSizeFallback;
              let index = session.nextChunkIndex || 0;
              let offset = index * chunkSize;
              while (offset < file.size) {
                const endExclusive = Math.min(offset + chunkSize, file.size);
                const chunk = file.slice(offset, endExclusive);
                await request(`/api/v1/uploads/${session.uploadId}/chunks/${index}`, {
                  method: "PUT",
                  headers: {
                    "Content-Type": "application/octet-stream",
                    "Content-Range": `bytes ${offset}-${endExclusive - 1}/${file.size}`
                  },
                  body: chunk
                });
                offset = endExclusive;
                index += 1;
                updateProgress(progressRow, (offset / Math.max(file.size, 1)) * 100);
                setStatus(`正在上传 ${file.name} (${fileIndex + 1}/${fileCount})`);
              }
              setStatus(`正在导入 ${file.name}`);
              await request(`/api/v1/uploads/${session.uploadId}/complete`, { method: "POST" });
              updateProgress(progressRow, 100);
            }

            loadFileList();
          </script>
        </body>
        </html>
        """
    }
}
