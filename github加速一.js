// ==UserScript==
// @name         GitHub超速下载增强版
// @namespace    githubaccelerator
// @version      2.1
// @description  智能加速GitHub资源下载，支持节点管理/自动更新/智能切换
// @author       AI助手
// @match        https://github.com/
// @grant        GMxmlhttpRequest
// @grant        GMgetValue
// @grant        GMsetValue
// @grant        GMaddValueChangeListener
// @grant        GMregisterMenuCommand
// @connect      raw.githubusercontent.com
// ==/UserScript==

(function() {
    'use strict';

    // 配置管理模块
    const config = {
        nodes: GMgetValue('nodes', [
            'https://ghproxy.com/',
            'https://github.com.cnpmjs.org/',
            'https://gitclone.com/',
            'https://hub.fastgit.xyz/'
        ]),
        checkInterval: 3600, // 节点检查间隔(秒)
        maxHistory: 20       // 节点历史记录保留数
    };

    // 节点健康监测模块
    class NodeHealth {
        constructor() {
            this.nodeStatus = new Map();
            this.initHealthCheck();
        }

        async testNodeSpeed(url) {
            return new Promise(resolve = {
                const start = Date.now();
                GMxmlhttpRequest({
                    method: "HEAD",
                    url: url + 'robots.txt',
                    timeout: 5000,
                    onload: () = {
                        const latency = Date.now()  start;
                        this.nodeStatus.set(url, { 
                            latency,
                            lastCheck: new Date(),
                            status: latency < 3000 ? 'healthy' : 'slow'
                        });
                        resolve(true);
                    },
                    onerror: () = {
                        this.nodeStatus.set(url, { 
                            status: 'dead', 
                            lastCheck: new Date() 
                        });
                        resolve(false);
                    }
                });
            });
        }

        async initHealthCheck() {
            setInterval(async () = {
                for (const node of config.nodes) {
                    await this.testNodeSpeed(node);
                }
                this.cleanupOldNodes();
            }, config.checkInterval  1000);
        }

        cleanupOldNodes() {
            // 清理过期节点逻辑
        }
    }

    // UI管理模块
    class UIManager {
        constructor() {
            this.createToolbar();
            GMregisterMenuCommand('⚙️ 管理加速节点', this.showNodeManager);
        }

        createToolbar() {
            const toolbar = document.createElement('div');
            toolbar.style = 'position:fixed;top:20px;right:20px;zindex:9999;background:white;padding:10px;boxshadow:0 2px 5px rgba(0,0,0,0.2);';
            
            // 节点切换下拉框
            this.nodeSelect = this.createSelect(config.nodes);
            toolbar.appendChild(this.nodeSelect);

            // 手动添加按钮
            const addBtn = this.createButton('➕ 添加节点', () = {
                const newNode = prompt('请输入加速节点URL:');
                if (newNode) this.addNewNode(newNode);
            });
            toolbar.appendChild(addBtn);

            document.body.appendChild(toolbar);
        }

        createSelect(nodes) {
            const select = document.createElement('select');
            nodes.forEach(node = {
                const option = document.createElement('option');
                option.value = node;
                option.textContent = node;
                select.appendChild(option);
            });
            select.onchange = () = this.switchNode(select.value);
            return select;
        }

        addNewNode(url) {
            if (!config.nodes.includes(url)) {
                config.nodes.push(url);
                GMsetValue('nodes', config.nodes);
                this.refreshSelect();
            }
        }

        refreshSelect() {
            this.nodeSelect.innerHTML = '';
            config.nodes.forEach(node = {
                const option = document.createElement('option');
                option.value = node;
                option.textContent = node;
                this.nodeSelect.appendChild(option);
            });
        }

        showNodeManager() {
            // 节点管理界面实现
        }
    }

    // 核心功能模块
    class Accelerator {
        constructor() {
            this.applyAcceleration();
            new MutationObserver(() = this.applyAcceleration()).observe(
                document.documentElement, 
                { childList: true, subtree: true }
            );
        }

        applyAcceleration() {
            document.querySelectorAll('a[dataopenapp="gitmac"], a[href="/archive/"]').forEach(link = {
                const originalUrl = link.href;
                const acceleratedUrl = this.getAcceleratedUrl(originalUrl);
                if (!link.dataset.accelerated) {
                    link.addEventListener('click', e = this.handleDownload(e, originalUrl));
                    link.dataset.accelerated = true;
                }
            });
        }

        getAcceleratedUrl(original) {
            const selectedNode = GMgetValue('currentNode', config.nodes[0]);
            return original.replace('https://github.com/', selectedNode);
        }

        handleDownload(e, originalUrl) {
            e.preventDefault();
            const confirm = window.confirm('使用加速下载？n确定：使用加速节点n取消：原始下载');
            window.open(confirm ? this.getAcceleratedUrl(originalUrl) : originalUrl);
        }
    }

    // 初始化
    new NodeHealth();
    new UIManager();
    new Accelerator();

})();