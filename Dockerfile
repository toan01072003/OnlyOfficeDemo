# =======================
# 1) RUNTIME (ASP.NET 5)
# =======================
FROM mcr.microsoft.com/dotnet/aspnet:5.0 AS base
WORKDIR /app
# (Không set ASPNETCORE_URLS ở đây để tránh expand $PORT lúc build)

# =======================
# 2) BUILD (SDK 5)
# =======================
FROM mcr.microsoft.com/dotnet/sdk:5.0 AS build
WORKDIR /src

# Copy csproj trước để cache restore
COPY OnlyOfficeDemo.csproj ./
RUN dotnet restore

# Copy source còn lại và publish
COPY . .
RUN dotnet publish -c Release -o /out

# =======================
# 3) FINAL IMAGE
# =======================
FROM base AS final
WORKDIR /app
COPY --from=build /out .

# (Tùy chọn) mở cổng dev local; Render vẫn dùng $PORT
EXPOSE 8080

# Bind đúng $PORT của Render khi container START (không phải lúc build)
# Nếu $PORT không có (chạy local), mặc định 8080
CMD ["bash","-lc","ASPNETCORE_URLS=http://0.0.0.0:${PORT:-8080} dotnet OnlyOfficeDemo.dll"]
