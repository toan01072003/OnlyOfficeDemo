# ===== Runtime =====
FROM mcr.microsoft.com/dotnet/aspnet:5.0 AS base
WORKDIR /app
# Render sẽ set biến $PORT; bắt buộc bind 0.0.0.0:$PORT
ENV ASPNETCORE_URLS=http://0.0.0.0:${PORT}

# ===== Build =====
FROM mcr.microsoft.com/dotnet/sdk:5.0 AS build
WORKDIR /src

# copy csproj trước để cache restore
COPY OnlyOfficeDemo.csproj ./
RUN dotnet restore

# copy phần còn lại và publish
COPY . .
RUN dotnet publish -c Release -o /out

# ===== Final =====
FROM base AS final
WORKDIR /app
COPY --from=build /out .
ENTRYPOINT ["dotnet", "OnlyOfficeDemo.dll"]
