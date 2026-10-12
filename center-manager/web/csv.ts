export function csvText(headers:string[],rows:unknown[][]){
 const cell=(v:unknown)=>{let s=String(v??'');if(/^[\s]*[=+\-@]/.test(s)||/^[\t\r\n]/.test(s))s="'"+s;return '"'+s.replace(/"/g,'""')+'"'};
 return '\uFEFF'+[headers,...rows].map(r=>r.map(cell).join(',')).join('\r\n');
}
export function downloadCsv(filename:string,headers:string[],rows:unknown[][]){const url=URL.createObjectURL(new Blob([csvText(headers,rows)],{type:'text/csv;charset=utf-8'}));const a=document.createElement('a');a.href=url;a.download=filename;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000)}
