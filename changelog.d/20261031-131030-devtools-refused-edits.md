type: Fixed

**`devtools`**: what cannot be edited (`DOM.setAttributesAsText`, `DOM.setOuterHTML`, other `DOM.set*` and `CSS.set*`, `Page.setDocumentContent`, cookies, DOM storage) answers an error instead of a false success; what clients send on attaching is still accepted.
