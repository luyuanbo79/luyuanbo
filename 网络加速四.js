// ==UserScript==
// @name         Universal Accelerator Master
// @namespace    http://tampermonkey.net/
// @version      1.2
// @description  全平台智能加速解决方案（非Watt Toolkit依赖）
// @author       AI Assistant
// @match        :///
// @grant        GMxmlhttpRequest
// @grant        GMgetValue
// @grant        GMsetValue
// @grant        GMregisterMenuCommand
// @connect      
// ==/UserScript==

(function() {
    'use strict';

    // 智能节点系统
    const accelerationEngine = {
        nodeSources: [
            "https://mirror.ghproxy.com/",
            "https://steamcommunity.com/",
            "https://hub.docker.com/",
            "https://translate.googleapis.com/",
            "https://ghapi.com/"
        ],
        customNodes: JSON.parse(GMgetValue('customNodes', '[]')),
        nodeSelector: function() {
            // 智能节点选择算法
            const platformMap = {
                'github.com': ['ghapi.com', 'ghproxy.com'],
                'steamcommunity.com': ['steamcn.com', 'steamcontent.com'],
                'docker.io': ['dockerproxy.com', 'mirror.aliyuncs.com'],
                'translate.googleapis.com': ['translate.naturali.io']
            };

            let target = Object.keys(platformMap).find(domain = location.host.includes(domain));
            return target ? platformMap[target] : null;
        }
    };

    // 请求拦截重定向
    const originFetch = window.fetch;
    window.fetch = async function(input, init) {
        const url = new URL(typeof input === 'string' ? input : input.url);
        const accelerator = accelerationEngine.nodeSelector();

        if (accelerator) {
            const mirrorUrl = url.href.replace(
                new RegExp(({Object.keys(accelerationEngine.nodeSources).join('|')})),
                accelerator[Math.floor(Math.random()  accelerator.length)]
            );
            console.log([智能加速] 重定向 {url.href} = {mirrorUrl});
            return originFetch(mirrorUrl, init);
        }
        return originFetch(input, init);
    };

    // 节点管理界面
    GMregisterMenuCommand("管理加速节点", () = {
        const panel = document.createElement('div');
        panel.style = / 样式细节省略 /;
        panel.innerHTML = 
            <h3智能节点管理</h3
            <div
                <input type="text" id="newNode" placeholder="输入新节点(例: https://mirror.example.com)"
                <button onclick="addNode()"添加节点</button
            </div
            <div id="nodeList"</div
        ;
        document.body.appendChild(panel);
    });

    // 动态规则更新
    setInterval(() = {
        GMxmlhttpRequest({
            method: "GET",
            url: "https://raw.fastgit.org/acceleratormirrorlist/main/list.json",
            onload: function(res) {
                const newNodes = JSON.parse(res.responseText);
                accelerationEngine.nodeSources = [...new Set([...accelerationEngine.nodeSources, ...newNodes])];
            }
        });
    }, 3600000); // 每小时更新
})();