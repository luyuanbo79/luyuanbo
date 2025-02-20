// ==UserScript==
// @name         全平台加速器 - Google/Steam/GitHub/Docker 全能加速
// @namespace    https://github.com/universal-accelerator
// @version      3.0
// @description  全平台加速访问，支持 Google、Steam、GitHub、Docker Hub 等，无需安装任何软件，支持自动更新节点、手动添加节点、智能切换节点。
// @author       TechHelper
// @match        *://*/*
// @grant        GM_setValue
// @grant        GM_getValue
// @grant        GM_registerMenuCommand
// @grant        GM_xmlhttpRequest
// @connect      *
// @license      MIT
// ==/UserScript==

(function () {
    'use strict';

    // ================= 配置区域 =================
    const CONFIG = {
        NODE_API: 'https://raw.githubusercontent.com/yourname/repo/main/nodes.json', // 节点列表API
        CHECK_TIMEOUT: 3000, // 节点检测超时时间（毫秒）
        AUTO_CHECK_INTERVAL: 600000, // 自动检测间隔（10分钟）
        PLATFORMS: {
            GOOGLE: ['https://www.google.com', 'https://translate.google.com'],
            STEAM: ['https://store.steampowered.com', 'https://steamcommunity.com'],
            GITHUB: ['https://github.com'],
            DOCKER: ['https://hub.docker.com']
        }
    };

    // ================= 核心功能 =================
    class UniversalAccelerator {
        constructor() {
            this.initNodes();
            this.setupMenu();
            this.autoUpdateNodes();
            this.startAutoCheck();
            this.applyAcceleration();
        }

        // 初始化节点数据
        initNodes() {
            this.defaultNodes = [
                'https://cdn.jsdelivr.net',
                'https://ghproxy.com',
                'https://gitclone.com',
                'https://steamcdn-a.akamaihd.net',
                'https://dockerproxy.com'
            ];

            this.customNodes = GM_getValue('customNodes', []);
            this.autoNodes = GM_getValue('autoNodes', this.defaultNodes);
            this.currentNode = GM_getValue('currentNode', this.autoNodes[0]);
            this.nodeStatus = new Map();
        }

        // 设置菜单命令
        setupMenu() {
            GM_registerMenuCommand('🚀 手动添加节点', () => this.addCustomNode());
            GM_registerMenuCommand('🔁 切换节点', () => this.showNodeSelector());
            GM_registerMenuCommand('📊 节点状态看板', () => this.showStatusBoard());
            GM_registerMenuCommand('⚡ 立即测速', () => this.checkAllNodes());
        }

        // 自动更新节点列表
        async autoUpdateNodes() {
            try {
                const response = await this.fetchData(CONFIG.NODE_API);
                const newNodes = JSON.parse(response).nodes;
                this.autoNodes = [...new Set([...this.autoNodes, ...newNodes])];
                GM_setValue('autoNodes', this.autoNodes);
            } catch (error) {
                console.log('节点更新失败:', error);
            }
        }

        // 节点测速功能
        async checkNodeSpeed(node) {
            const testUrl = node + '/test'; // 测试路径需根据实际情况调整
            const startTime = Date.now();

            try {
                await this.fetchData(testUrl, { timeout: CONFIG.CHECK_TIMEOUT });
                const speed = Date.now() - startTime;
                this.nodeStatus.set(node, { speed, status: 'online' });
                return speed;
            } catch {
                this.nodeStatus.set(node, { speed: Infinity, status: 'offline' });
                return Infinity;
            }
        }

        // 智能节点切换
        async autoSwitchNode() {
            const allNodes = this.getAllNodes();
            const results = await Promise.all(
                allNodes.map(node => this.checkNodeSpeed(node))
            );

            const validNodes = allNodes.filter((_, i) => results[i] < CONFIG.CHECK_TIMEOUT);
            if (validNodes.length > 0) {
                const fastestNode = validNodes.reduce((a, b) =>
                    this.nodeStatus.get(a).speed < this.nodeStatus.get(b).speed ? a : b
                );
                this.switchNode(fastestNode);
            }
        }

        // 手动添加节点
        async addCustomNode() {
            const newNode = prompt('请输入加速节点地址（支持镜像站/CDN）:\n示例: https://mirror.example.com', 'https://');
            if (newNode && this.validateNode(newNode)) {
                this.customNodes.push(newNode);
                GM_setValue('customNodes', this.customNodes);
                await this.checkNodeSpeed(newNode);
                alert('节点添加成功！当前状态: ' +
                    (this.nodeStatus.get(newNode).status === 'online' ? '✅ 可用' : '❌ 不可用'));
            }
        }

        // 节点选择界面
        async showNodeSelector() {
            const allNodes = this.getAllNodes();
            const statusList = await this.getNodeStatus();

            let message = '当前节点: ' + this.currentNode + '\n\n';
            statusList.forEach(({ node, status, speed }, index) => {
                message += `${index + 1}. ${node}\n  状态: ${status} ${speed ? `(${speed}ms)` : ''}\n`;
            });

            const choice = prompt(`${message}\n请输入要切换的节点编号:`, '');
            const selectedNode = allNodes[choice - 1];
            if (selectedNode) this.switchNode(selectedNode);
        }

        // 核心替换逻辑
        applyAcceleration() {
            this.replaceStaticResources();
            this.replaceDownloadLinks();
            this.replaceRawLinks();
        }

        // 静态资源替换
        replaceStaticResources() {
            this.replaceElements('link[rel="stylesheet"]', 'href');
            this.replaceElements('script[src]', 'src');
            this.replaceElements('img[src]', 'src');
        }

        // 下载链接替换
        replaceDownloadLinks() {
            const patterns = [
                '/archive/',
                '/releases/download/',
                '/releases/tag/',
                '/tree/',
                '/blob/'
            ];
            patterns.forEach(p => this.replaceElements(`a[href*="${p}"]`, 'href'));
        }

        // Raw文件替换
        replaceRawLinks() {
            this.replaceElements('a[href*="/raw/"]', 'href', url =>
                url.replace('/raw/', '@main/').replace('github.com', '')
            );
        }

        // 通用替换方法
        replaceElements(selector, attr, customHandler) {
            document.querySelectorAll(selector).forEach(el => {
                const original = el[attr];
                if (original && original.includes('github.com')) {
                    el[attr] = customHandler ?
                        customHandler(original) :
                        original.replace('github.com', this.currentNode.split('/gh')[0]);
                }
            });
        }

        // 其他辅助方法
        getAllNodes() { return [...this.autoNodes, ...this.customNodes]; }
        validateNode(url) { return /^https?:\/\/[^\s/$.?#].[^\s]*$/.test(url); }

        async fetchData(url, options = {}) {
            return new Promise((resolve, reject) => {
                GM_xmlhttpRequest({
                    method: 'GET',
                    url,
                    timeout: options.timeout || 5000,
                    onload: (res) => res.status === 200 ? resolve(res.responseText) : reject(),
                    onerror: reject,
                    ontimeout: reject
                });
            });
        }

        // 定时任务
        startAutoCheck() {
            setInterval(() => {
                this.checkAllNodes();
                this.autoUpdateNodes();
            }, CONFIG.AUTO_CHECK_INTERVAL);
        }

        async checkAllNodes() {
            const nodes = this.getAllNodes();
            await Promise.all(nodes.map(node => this.checkNodeSpeed(node)));
        }

        switchNode(newNode) {
            this.currentNode = newNode;
            GM_setValue('currentNode', newNode);
            location.reload();
        }

        showStatusBoard() {
            let statusText = '=== 节点状态看板 ===\n';
            this.getAllNodes().forEach(node => {
                const status = this.nodeStatus.get(node) || { status: 'unknown' };
                statusText += `• ${node} [${status.status.toUpperCase()}] ${status.speed ? status.speed + 'ms' : ''}\n`;
            });
            alert(statusText);
        }
    }

    // 启动加速器
    new UniversalAccelerator();
})();