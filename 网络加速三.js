// ==UserScript==
// @name         Omni Accelerator Suite
// @namespace    omniaccelerator
// @version      6.2
// @description  全平台智能加速解决方案
// @match        :///
// @grant        GMxmlhttpRequest
// @grant        GMsetValue
// @grant        GMgetValue
// @grant        GMregisterMenuCommand
// @grant        GMnotification
// @grant        GMaddStyle
// @grant        GMgetResourceText
// @connect      
// @require      https://cdnjs.cloudflare.com/ajax/libs/vue/3.2.47/vue.global.min.js
// @require      https://cdnjs.cloudflare.com/ajax/libs/axios/1.3.4/axios.min.js
// @resource     nodes https://cdn.example.com/nodesv6.json
// ==/UserScript==

/ 架构说明：
1. 节点管理模块  负责节点的增删改查
2. 智能路由模块  自动选择最佳节点
3. 协议适配模块  处理不同协议加速
4. 配置界面模块  提供可视化操作界面
/

class OmniAccelerator {
    constructor() {
        this.services = {
            'github': {
                patterns: ['github.com', 'raw.githubusercontent.com'],
                strategies: ['mirror', 'proxy']
            },
            'steam': {
                patterns: ['steamcommunity.com', 'store.steampowered.com'],
                strategies: ['reverseproxy']
            },
            'docker': {
                patterns: ['docker.io', 'hub.docker.com'],
                strategies: ['registrymirror']
            },
            'google': {
                patterns: ['google.com', 'translate.google.com'],
                strategies: ['geolocation']
            }
        };
        this.init();
    }

    async init() {
        await this.loadNodes();
        this.initUI();
        this.initInterceptors();
        this.startNodeMonitor();
    }

    // ================= 节点管理模块 =================
    async loadNodes() {
        this.nodes = GMgetValue('nodes', []);
        const publicNodes = await this.fetchPublicNodes();
        this.nodes = this.mergeNodes(this.nodes, publicNodes);
        GMsetValue('nodes', this.nodes);
    }

    async fetchPublicNodes() {
        try {
            const { data } = await axios.get('https://noderegistry.example.com/v3/nodes');
            return data.nodes;
        } catch (error) {
            return [];
        }
    }

    mergeNodes(local, remote) {
        return [...new Map([...local, ...remote].map(n = [n.id, n])).values()];
    }

    addCustomNode(node) {
        this.nodes.push(node);
        GMsetValue('nodes', this.nodes);
    }

    // ================= 智能路由模块 =================
    selectNode(serviceType) {
        const candidates = this.nodes.filter(n = 
            n.services.includes(serviceType) &&
            n.status === 'healthy'
        );
        
        return this.strategySelector(candidates);
    }

    strategySelector(nodes) {
        // 综合评分算法
        return nodes.sort((a, b) = {
            const scoreA = (a.speed  0.6) + (a.stability  0.4);
            const scoreB = (b.speed  0.6) + (b.stability  0.4);
            return scoreB  scoreA;
        })[0];
    }

    // ================= 协议处理模块 =================
    handleRequest(url) {
        const service = this.detectService(url.hostname);
        if (!service) return url.href;

        const node = this.selectNode(service);
        return node ? this.applyNode(url, node) : url.href;
    }

    applyNode(url, node) {
        switch(node.type) {
            case 'mirror':
                return this.applyMirror(url, node);
            case 'proxy':
                return this.applyProxy(url, node);
            case 'cdn':
                return this.applyCDN(url, node);
            default:
                return url.href;
        }
    }

    applyMirror(url, node) {
        return url.href.replace(url.host, node.endpoint);
    }

    // ================= 请求拦截模块 =================
    initInterceptors() {
        // Fetch拦截
        const originalFetch = window.fetch;
        window.fetch = async (input, init) = {
            const newUrl = this.handleRequest(new URL(input.url));
            return originalFetch(newUrl, init);
        };

        // XHR拦截
        const originalOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
            const newUrl = this.handleRequest(new URL(url));
            originalOpen.call(this, method, newUrl);
        };

        // WebSocket处理
        this.rewriteWebSocket();
    }

    rewriteWebSocket() {
        const originalWS = WebSocket;
        window.WebSocket = function(url, protocols) {
            const service = this.detectService(new URL(url).hostname);
            const node = this.selectNode(service);
            const newUrl = node ? url.replace(/^ws(s?)://(.+?)//, ws1://{node.wsEndpoint}/) : url;
            return new originalWS(newUrl, protocols);
        };
    }

    // ================= 服务检测模块 =================
    detectService(hostname) {
        return Object.keys(this.services).find(service = 
            this.services[service].patterns.some(pattern = 
                hostname === pattern || hostname.endsWith(.{pattern})
            )
        );
    }

    // ================= 状态监控模块 =================
    startNodeMonitor() {
        setInterval(() = {
            this.nodes.forEach(async node = {
                node.status = await this.checkNodeHealth(node);
            });
            GMsetValue('nodes', this.nodes);
        }, 300000);
    }

    async checkNodeHealth(node) {
        try {
            const start = Date.now();
            await axios.head(node.healthCheck);
            node.latency = Date.now()  start;
            return 'healthy';
        } catch {
            return 'unhealthy';
        }
    }

    // ================= 用户界面模块 =================
    initUI() {
        const app = Vue.createApp({
            data() {
                return {
                    nodes: GMgetValue('nodes', []),
                    newNode: {
                        name: '',
                        endpoint: '',
                        type: 'mirror',
                        services: []
                    },
                    selectedService: 'github'
                };
            },
            computed: {
                filteredNodes() {
                    return this.nodes.filter(n = 
                        n.services.includes(this.selectedService)
                    );
                }
            },
            methods: {
                addNode() {
                    this.nodes.push({...this.newNode});
                    GMsetValue('nodes', this.nodes);
                    this.newNode = { name: '', endpoint: '', type: 'mirror', services: [] };
                },
                removeNode(index) {
                    this.nodes.splice(index, 1);
                    GMsetValue('nodes', this.nodes);
                }
            }
        });

        const vm = app.mount(this.createPanel());
    }

    createPanel() {
        const panel = document.createElement('div');
        panel.id = 'omniacceleratorpanel';
        GMaddStyle(
            omniacceleratorpanel {
                position: fixed;
                bottom: 20px;
                right: 20px;
                background: rgba(0,0,0,0.95);
                color: fff;
                padding: 20px;
                borderradius: 12px;
                width: 400px;
                zindex: 999999;
                boxshadow: 0 4px 6px rgba(0,0,0,0.1);
            }
            .nodeitem {
                margin: 10px 0;
                padding: 10px;
                background: rgba(255,255,255,0.1);
                borderradius: 6px;
            }
        );
        document.body.appendChild(panel);
        return panel;
    }
}

// ================= 初始化 =================
new OmniAccelerator();

// ================= 功能扩展 =================
GMregisterMenuCommand("手动更新节点", () = {
    new OmniAccelerator().loadNodes();
});

GMregisterMenuCommand("打开控制面板", () = {
    document.getElementById('omniacceleratorpanel').style.display = 'block';
});