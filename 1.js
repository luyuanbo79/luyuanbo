// ==UserScript==
// @name         GitHub 网站与下载加速器
// @namespace    http://tampermonkey.net/
// @version      1.0
// @description  加速 GitHub 网站访问和下载，支持自动更新加速节点、手动添加加速节点以及自动或手动切换加速节点。
// @author       Your Name
// @match        https://github.com/*
// @grant        GM_setValue
// @grant        GM_getValue
// @grant        GM_registerMenuCommand
// @grant        GM_unregisterMenuCommand
// ==/UserScript==

(function () {
    'use strict';

    // 默认加速节点
    const defaultNode = "https://cdn.jsdelivr.net/gh";

    // 获取当前加速节点
    let currentNode = GM_getValue("currentNode", defaultNode);

    // 手动添加的节点列表
    let customNodes = GM_getValue("customNodes", []);

    // 自动更新节点列表
    let autoUpdateNodes = GM_getValue("autoUpdateNodes", [defaultNode]);

    // 注册菜单命令
    GM_registerMenuCommand("手动添加加速节点", addCustomNode);
    GM_registerMenuCommand("切换加速节点", switchNode);
    GM_registerMenuCommand("查看当前节点", showCurrentNode);

    // 自动更新节点
    function updateNodes() {
        // 这里可以添加自动更新节点的逻辑，例如从某个API获取最新的节点列表
        // 示例：autoUpdateNodes = fetchLatestNodes();
        GM_setValue("autoUpdateNodes", autoUpdateNodes);
    }

    // 手动添加节点
    function addCustomNode() {
        let newNode = prompt("请输入新的加速节点URL：");
        if (newNode) {
            customNodes.push(newNode);
            GM_setValue("customNodes", customNodes);
            alert("节点添加成功！");
        }
    }

    // 切换节点
    function switchNode() {
        let allNodes = autoUpdateNodes.concat(customNodes);
        let nodeList = allNodes.map((node, index) => `${index + 1}. ${node}`).join("\n");
        let choice = prompt(`当前节点：${currentNode}\n请选择要切换的节点：\n${nodeList}`);
        if (choice && allNodes[choice - 1]) {
            currentNode = allNodes[choice - 1];
            GM_setValue("currentNode", currentNode);
            alert(`节点已切换为：${currentNode}`);
            location.reload(); // 刷新页面以应用新节点
        }
    }

    // 显示当前节点
    function showCurrentNode() {
        alert(`当前使用的加速节点是：${currentNode}`);
    }

    // 替换 GitHub 静态资源链接
    function replaceStaticResources() {
        const staticSelectors = [
            'link[rel="stylesheet"]',
            'script[src]',
            'img[src]'
        ];

        staticSelectors.forEach(selector => {
            document.querySelectorAll(selector).forEach(element => {
                if (element.href || element.src) {
                    const url = element.href || element.src;
                    if (url.includes("github.com")) {
                        const newUrl = url.replace("https://github.com", currentNode);
                        if (element.href) element.href = newUrl;
                        if (element.src) element.src = newUrl;
                    }
                }
            });
        });
    }

    // 替换 GitHub 下载链接
    function replaceDownloadLinks() {
        const downloadSelectors = [
            'a[href*="/archive/"]', // 源码下载链接
            'a[href*="/releases/download/"]', // Release 文件下载链接
            'a[href*="/raw/"]' // Raw 文件下载链接
        ];

        downloadSelectors.forEach(selector => {
            document.querySelectorAll(selector).forEach(link => {
                const originalUrl = link.href;
                const acceleratedUrl = originalUrl.replace("https://github.com", currentNode);
                link.href = acceleratedUrl;
            });
        });
    }

    // 初始化
    updateNodes();
    replaceStaticResources();
    replaceDownloadLinks();

    // 监听页面变化，动态替换链接
    const observer = new MutationObserver(() => {
        replaceStaticResources();
        replaceDownloadLinks();
    });
    observer.observe(document.body, { childList: true, subtree: true });
})();