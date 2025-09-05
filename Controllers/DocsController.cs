using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using OnlyOfficeDemo.Models;
using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using System.Security.Cryptography;
using System.Text;

namespace OnlyOfficeDemo.Controllers
{
    public class DocsController : Controller
    {
        private readonly IHttpClientFactory _httpFactory;
        private readonly ILogger<DocsController> _logger;
        private readonly IConfiguration _cfg;

        // api.js của ONLYOFFICE
        private string DocumentServerOrigin => _cfg["OnlyOffice:DocumentServerOrigin"] ?? "http://localhost:8080";
        private const string ApiJsPath = "/web-apps/apps/api/documents/api.js";

        private static readonly string[] AllowedExtensions = new[]
        {
            ".docx",".doc",".xlsx",".xls",".pptx",".ppt",".odt",".ods",".odp",".txt",".csv"
        };
        


        public DocsController(IHttpClientFactory httpFactory, ILogger<DocsController> logger, IConfiguration cfg)
        {
            _httpFactory = httpFactory;
            _logger = logger;
            _cfg = cfg;
        }
        


        private string DocsRoot
        {
            get
            {
                var p = Path.Combine(Directory.GetCurrentDirectory(), "wwwroot", "docs");
                Directory.CreateDirectory(p);
                return p;
            }
        }

        private string PreviewsRoot
        {
            get
            {
                var p = Path.Combine(Directory.GetCurrentDirectory(), "wwwroot", "previews");
                Directory.CreateDirectory(p);
                return p;
            }
        }

        private string GetPreviewPdfPath(string name)
        {
            var baseName = Path.GetFileNameWithoutExtension(name);
            return Path.Combine(PreviewsRoot, $"{baseName}.pdf");
        }

        // Home: danh sách + upload + (iframe PDF)
        [HttpGet]
        public IActionResult Index()
        {
            var files = Directory.GetFiles(DocsRoot)
                                 .Select(Path.GetFileName)
                                 .OrderBy(n => n)
                                 .ToList();
            ViewBag.Files = files;
            ViewBag.ApiJs = $"{DocumentServerOrigin}{ApiJsPath}";
            return View();
        }

        // Upload file rồi mở editor
        [HttpPost]
        [RequestSizeLimit(200_000_000)] // ~200MB
        public async Task<IActionResult> Upload()
        {
            if (!Request.HasFormContentType || Request.Form.Files.Count == 0)
                return BadRequest("No file uploaded.");

            var file = Request.Form.Files[0];
            var ext = Path.GetExtension(file.FileName).ToLowerInvariant();
            if (!AllowedExtensions.Contains(ext))
                return BadRequest("Định dạng chưa được hỗ trợ.");

            var safeName = SanitizeFilename(Path.GetFileName(file.FileName));
            safeName = EnsureUniqueName(safeName);

            var savePath = Path.Combine(DocsRoot, safeName);
            using (var fs = System.IO.File.Create(savePath))
                await file.CopyToAsync(fs);

            // Tạo/ cập nhật preview PDF
            await EnsurePreviewPdfAsync(safeName);

            return RedirectToAction("Edit", new { name = safeName });
        }

        // Phục vụ file cho Document Server tải về
        [HttpGet("/files/{name}")]
        [HttpHead("/files/{name}")]
        public IActionResult FilePublic(string name)
        {
            var path = Path.Combine(DocsRoot, name);
            if (!System.IO.File.Exists(path)) return NotFound("File not found.");

            var provider = new FileExtensionContentTypeProvider();
            if (!provider.TryGetContentType(path, out var contentType)) contentType = "application/octet-stream";

            // Trả file vật lý, để tránh load toàn bộ vào RAM và hỗ trợ HEAD tốt hơn
            return PhysicalFile(path, contentType, enableRangeProcessing: true);
        }

        // Nhúng editor
        [HttpGet]
        public IActionResult Edit(string name, string mode = "edit")
        {
            _logger.LogInformation("Edit action called for file: {FileName}, mode: {Mode}", name, mode);
            
            if (string.IsNullOrWhiteSpace(name))
            {
                _logger.LogWarning("Edit action called with empty filename");
                return RedirectToAction("Index");
            }
            
            var storagePath = Path.Combine(DocsRoot, name);
            _logger.LogInformation("Storage path: {StoragePath}", storagePath);
            
            if (!System.IO.File.Exists(storagePath))
            {
                _logger.LogWarning("File not found: {StoragePath}", storagePath);
                return NotFound("File not found.");
            }

            var configuredHost = _cfg["OnlyOffice:PublicHost"];
            var scheme = _cfg["OnlyOffice:Scheme"] ?? (Request.Scheme ?? "http");
            var publicHost = string.IsNullOrWhiteSpace(configuredHost) ? Request.Host.ToString() : configuredHost;
            
            _logger.LogInformation("Configuration - DocumentServerOrigin: {Origin}, PublicHost: {PublicHost}, Scheme: {Scheme}", 
                DocumentServerOrigin, publicHost, scheme);

            var fileUrl = Url.ActionLink("FilePublic", null, new { name }, scheme, publicHost);
            var docKey = ComputeDocKey(name, storagePath);
            var fileType = GetFileTypeByExtension(Path.GetExtension(name));
            var callbackUrl = Url.ActionLink("Save", "Docs", new { name }, scheme, publicHost);
            
            _logger.LogInformation("Generated URLs - FileUrl: {FileUrl}, CallbackUrl: {CallbackUrl}", fileUrl, callbackUrl);

            // Create document info
            _logger.LogInformation("Preparing editor configuration without JWT token");
            
            var configPayload = new
            {
                document = new
                {
                    fileType = fileType,
                    key = docKey,
                    title = name,
                    url = fileUrl,
                },
                editorConfig = new
                {
                    mode = mode == "view" ? "view" : "edit",
                    callbackUrl = callbackUrl,
                    user = new { id = "u1", name = "Demo User" },
                    lang = "en",
                    customization = new
                    {
                        goback = new
                        {
                            url = Url.Action("Index", "Docs")
                        }
                    }
                },
                width = "100%",
                height = "100%",
                type = "desktop"
            };
            
            _logger.LogInformation("Config payload: {ConfigPayload}", System.Text.Json.JsonSerializer.Serialize(configPayload));

            var vm = new OnlyOfficeConfig
            {
                DocumentServerApiJs = $"{DocumentServerOrigin}{ApiJsPath}",
                Config = configPayload
            };

            return View(vm);
        }
        [HttpGet]
public async Task<IActionResult> RegeneratePreviews()
{
    var files = Directory.GetFiles(DocsRoot).Select(Path.GetFileName).OrderBy(n => n).ToList();
    var report = new System.Text.StringBuilder();
    report.AppendLine("<h2>Preview Regenerator</h2><ul>");

    foreach (var f in files)
    {
        await EnsurePreviewPdfAsync(f!);
        var pdf = GetPreviewPdfPath(f!);
        var err = Path.ChangeExtension(pdf, ".err.txt");

        if (System.IO.File.Exists(pdf))
        {
            report.AppendLine($"<li>{f} — ✅ <a href=\"/previews/{Uri.EscapeDataString(Path.GetFileNameWithoutExtension(f))}.pdf\" target=\"_blank\">open PDF</a></li>");
        }
        else if (System.IO.File.Exists(err))
        {
            var errText = System.IO.File.ReadAllText(err);
            report.AppendLine($"<li>{f} — ❌ ERROR<pre style='white-space:pre-wrap;border:1px solid #ddd;padding:8px'>{System.Net.WebUtility.HtmlEncode(errText)}</pre></li>");
        }
        else
        {
            report.AppendLine($"<li>{f} — ❌ no pdf and no error file</li>");
        }
    }

    report.AppendLine("</ul>");
    return Content(report.ToString(), "text/html; charset=utf-8");
}


        // ONLYOFFICE gọi về khi save
        [HttpPost]
        public async Task<IActionResult> Save(string name)
        {
            using var reader = new StreamReader(Request.Body);
            var body = await reader.ReadToEndAsync();
            _logger.LogInformation("ONLYOFFICE callback body: {Body}", body);

            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;
            var status = root.GetProperty("status").GetInt32();

            // 2 = MustSave, 6 = MustForceSave
            if (status == 2 || status == 6)
            {
                var url = root.GetProperty("url").GetString();
                var targetPath = Path.Combine(DocsRoot, name);

                var client = _httpFactory.CreateClient();
                var bytes = await client.GetByteArrayAsync(url);
                await System.IO.File.WriteAllBytesAsync(targetPath, bytes);

                // Cập nhật preview PDF
                await EnsurePreviewPdfAsync(name);

                return Json(new { error = 0 });
            }

            return Json(new { error = 0 });
        }

        // ===== Convert DOCX/XLSX/PPTX → PDF bằng ONLYOFFICE ConvertService (polling) =====

        private async Task EnsurePreviewPdfAsync(string name)
        {
            var srcPath = Path.Combine(DocsRoot, name);
    if (!System.IO.File.Exists(srcPath)) return;

    var pdfPath = GetPreviewPdfPath(name);
    var errPath = Path.ChangeExtension(pdfPath, ".err.txt");

    var needBuild = !System.IO.File.Exists(pdfPath) ||
                    System.IO.File.GetLastWriteTimeUtc(srcPath) > System.IO.File.GetLastWriteTimeUtc(pdfPath);
    if (!needBuild) return;

    try
    {
        var configuredHost = _cfg["OnlyOffice:PublicHost"];
        var scheme        = _cfg["OnlyOffice:Scheme"] ?? (Request.Scheme ?? "http");
        var publicHost    = string.IsNullOrWhiteSpace(configuredHost) ? Request.Host.ToString() : configuredHost;

        // URL public để Document Server tải file gốc
        var fileUrl = Url.ActionLink("FilePublic", null, new { name }, scheme, publicHost);

        var documentServerOrigin = _cfg["OnlyOffice:DocumentServerOrigin"] ?? "http://localhost:8080";
        var convertEndpoint = $"{documentServerOrigin.TrimEnd('/')}/ConvertService.ashx";

        var fileType = Path.GetExtension(name).Trim('.').ToLowerInvariant(); // docx/xlsx/pptx/...
        var key = ComputeDocKey(name, srcPath);

        // Dùng async=true rồi poll
        var payload = new
        {
            async = true,
            url = fileUrl,
            outputtype = "pdf",
            filetype = fileType,
            title = name,
            key = key
        };

        using var client = _httpFactory.CreateClient();

        async Task<(bool endConvert, string fileUrl, int percent)> CallOnceAsync()
        {
            var req = new HttpRequestMessage(HttpMethod.Post, convertEndpoint)
            {
                Content = new StringContent(System.Text.Json.JsonSerializer.Serialize(payload),
                                            System.Text.Encoding.UTF8, "application/json")
            };
            req.Headers.Accept.ParseAdd("application/json");

            var resp = await client.SendAsync(req);
            var body = await resp.Content.ReadAsStringAsync();
            var ct = resp.Content.Headers.ContentType?.MediaType ?? "";

            // Nếu không phải JSON -> ghi chẩn đoán và ném lỗi có ngữ cảnh
            if (!ct.Contains("json", StringComparison.OrdinalIgnoreCase))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(pdfPath)!);
                var head = body.Length > 500 ? body.Substring(0, 500) : body;
                var diag = $"[{DateTimeOffset.Now}] HTTP {(int)resp.StatusCode} {resp.ReasonPhrase}\n" +
                           $"Content-Type: {ct}\nEndpoint: {convertEndpoint}\n" +
                           $"Payload.url: {fileUrl}\nPayload.filetype: {fileType}\n\n" +
                           $"Body(head 500):\n{head}\n";
                await System.IO.File.WriteAllTextAsync(errPath, diag);
                throw new Exception("ConvertService did not return JSON (see .err.txt for details).");
            }

            using var doc = System.Text.Json.JsonDocument.Parse(body);
            var root = doc.RootElement;

            int percent = root.TryGetProperty("percent", out var p) ? p.GetInt32() : 0;
            bool endConvert = root.TryGetProperty("endConvert", out var ec) && ec.GetBoolean();
            string resultUrl = root.TryGetProperty("fileUrl", out var fu) ? fu.GetString() : null;

            if (endConvert)
            {
                if (string.IsNullOrEmpty(resultUrl))
                    throw new Exception("endConvert=true nhưng không có fileUrl (JSON).");

                var bytes = await client.GetByteArrayAsync(resultUrl);
                if (bytes == null || bytes.Length == 0)
                    throw new Exception("Tải PDF về nhưng dữ liệu rỗng.");

                Directory.CreateDirectory(Path.GetDirectoryName(pdfPath)!);
                await System.IO.File.WriteAllBytesAsync(pdfPath, bytes);

                if (System.IO.File.Exists(errPath)) System.IO.File.Delete(errPath);
            }

            return (endConvert, resultUrl ?? "", percent);
        }

        const int maxTries = 30;
        for (int i = 1; i <= maxTries; i++)
        {
            var (endConvert, _, percent) = await CallOnceAsync();
            _logger.LogInformation("Convert poll {Try}/{Max} key={Key} percent={Percent} end={End}",
                i, maxTries, key, percent, endConvert);
            if (endConvert) return;
            await Task.Delay(TimeSpan.FromSeconds(3));
        }

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(pdfPath)!);
            // One more attempt with async=false to capture immediate error message
            var payloadSync = new
            {
                async = false,
                url = fileUrl,
                outputtype = "pdf",
                filetype = fileType,
                title = name,
                key = key
            };
            var req2 = new HttpRequestMessage(HttpMethod.Post, convertEndpoint)
            {
                Content = new StringContent(System.Text.Json.JsonSerializer.Serialize(payloadSync),
                                            System.Text.Encoding.UTF8, "application/json")
            };
            req2.Headers.Accept.ParseAdd("application/json");
            var resp2 = await client.SendAsync(req2);
            var body2 = await resp2.Content.ReadAsStringAsync();

            var diag = $"[{DateTimeOffset.Now}] Timeout waiting for ConvertService (async).\\n" +
                      $"Name: {name}\\nKey: {key}\\n" +
                      $"Endpoint: {convertEndpoint}\\n" +
                      $"Payload.url: {fileUrl}\\nPayload.filetype: {fileType}\\n";
            diag += $"\\nSynchronous probe response (status {(int)resp2.StatusCode}):\\n{body2}\\n";
            await System.IO.File.WriteAllTextAsync(errPath, diag);
        }
        catch { }
        throw new Exception("Hết thời gian chờ convert PDF (async=true).");
    }
    catch (Exception ex)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(pdfPath)!);
        await System.IO.File.WriteAllTextAsync(errPath,
            $"[{DateTimeOffset.Now}] Convert preview failed for {name}\n{ex}\n");
        _logger.LogError(ex, "Convert preview failed for {Name}", name);
    }
}



        // ===== Helpers =====

        private string GetFileTypeByExtension(string ext)
        {
            ext = (ext ?? "").Trim('.').ToLowerInvariant();
            return ext switch
            {
                "docx" => "docx",
                "xlsx" => "xlsx",
                "pptx" => "pptx",
                "doc"  => "doc",
                "xls"  => "xls",
                "ppt"  => "ppt",
                "odt"  => "odt",
                "ods"  => "ods",
                "odp"  => "odp",
                "txt"  => "txt",
                "csv"  => "csv",
                _ => "docx"
            };
        }

        private string SanitizeFilename(string name)
        {
            var invalid = Path.GetInvalidFileNameChars();
            var cleaned = new string(name.Select(ch => invalid.Contains(ch) ? '_' : ch).ToArray());
            return string.IsNullOrWhiteSpace(cleaned) ? $"upload_{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}" : cleaned;
        }

        private string EnsureUniqueName(string name)
        {
            var path = Path.Combine(DocsRoot, name);
            if (!System.IO.File.Exists(path)) return name;

            var baseName = Path.GetFileNameWithoutExtension(name);
            var ext = Path.GetExtension(name);
            int i = 1;
            string candidate;
            do
            {
                candidate = $"{baseName} ({i++}){ext}";
            } while (System.IO.File.Exists(Path.Combine(DocsRoot, candidate)));

            return candidate;
        }

        private string ComputeDocKey(string name, string filePath)
        {
            try
            {
                var ticks = System.IO.File.Exists(filePath)
                    ? System.IO.File.GetLastWriteTimeUtc(filePath).Ticks
                    : DateTime.UtcNow.Ticks;
                var raw = $"{name}|{ticks}";
                using var sha = SHA256.Create();
                var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(raw));
                var hex = BitConverter.ToString(hash).Replace("-", string.Empty).ToLowerInvariant();
                // OnlyOffice key limit is 128 chars; hex is 64 chars, safe ASCII
                return hex.Length <= 128 ? hex : hex.Substring(0, 128);
            }
            catch
            {
                // Fallback to a safe random GUID if hashing fails
                return Guid.NewGuid().ToString("N");
            }
        }
    }
}
