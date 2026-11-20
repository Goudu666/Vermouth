# Vermouth

面向 Apple Silicon Mac 的开源、原生 macOS Windows 应用与游戏转译启动器。

> **当前状态**：项目初始化阶段（已完成 PRD 规划，v0.1 核心功能开发中）。完整需求与架构设计见 [PRD.md](./PRD.md)。

## 简介

Vermouth 基于开源 Wine 与开源图形转译栈（`DXMT` / `DXVK-macOS` / `WineD3D`），使用纯 Swift 6 + SwiftUI（SwiftPM 构建，无需完整 Xcode）封装容器管理、图形后端切换、程序安装启动与日志诊断流程，让配置透明、排查可控。

## 规划核心能力（v0.1）

- **环境预检与引擎管理**：只读检测 Apple Silicon、Rosetta 2、Homebrew 与本机多套 Wine 引擎（优先支持 `gcenx/wine/wine-crossover`）。
- **容器全生命周期管理**：每个容器由独立 `WINEPREFIX` 与人类可读 `bottle.json` 组成，支持 Windows 版本、MSync/ESync、Retina DPI、Metal Performance HUD 与中文环境一键补全。
- **容器级图形转译层切换**：按容器部署与回退 `WineD3D`、`DXVK-macOS`、`DXMT`。
- **安装、启动与配方**：支持 `.exe` / `.msi` 安装运行、可执行程序扫描与 `.recipe.json` 兼容配方。
- **实时日志与崩溃诊断**：流式捕获 Wine 日志并对缺失 DLL、隔离属性、32/64 位架构不匹配等常见错误给出排查建议。
- **高级覆写与轻量备份**：可视化配置 `WINEDLLOVERRIDES` 并提供配置/存档目录快照与回滚。

## 目标运行与构建环境

- Apple Silicon Mac（macOS 14 Sonoma 及以上）
- Apple Command Line Tools（Swift 6 / SwiftPM，无需完整 Xcode）
- Rosetta 2 与本机安装的开源 Wine 引擎（如 Homebrew Cask `gcenx/wine/wine-crossover`）

## 合规声明

Vermouth 仅作为开源编排与管理外壳，**不分发**任何游戏本体、商业软件、商业版 Wine 或 Apple 专有组件（如 `D3DMetal` / Game Porting Toolkit 二进制），亦不提供任何绕过在线反作弊系统（EAC / BattlEye / Vanguard 等）的功能。

## 许可证

本项目基于 [MIT License](./LICENSE) 开源。
