# ---- Runtime base (ASP.NET 5.0) ----
FROM mcr.microsoft.com/dotnet/aspnet:5.0 AS base
WORKDIR /app
# Render sẽ đặt biến $PORT; ta bind 0.0.0.0 và dùng PORT đó
ENV ASPNETCORE_URLS=http://0.0.0.0:${PORT}

# ---- Build (SDK 5.0) ----
FROM mcr.microsoft.com/dotnet/sdk:5.0 AS build
WORKDIR /src
COPY . .
RUN dotnet restore
RUN dotnet publish -c Release -o /out

# ---- Final ----
FROM base AS final
WORKDIR /app
COPY --from=build /out .
# Đổi YourApp.dll thành tên dll thực tế (theo <AssemblyName/> hoặc tên project)
ENTRYPOINT ["dotnet", "YourApp.dll"]
