import {useEffect,useState} from 'react';
import {db,friendlyError,getTossConfig,paymentAction} from './client';
import {money} from '../lib/model';

export function BillingSetup({centerId,isOwner}:{centerId:string;isOwner:boolean}){
 const [busy,setBusy]=useState(false),[message,setMessage]=useState(''),[config,setConfig]=useState<any>(null);
 async function load(){try{setConfig(await getTossConfig(centerId));}catch(e){setMessage(friendlyError(e));}}
 useEffect(()=>{void load()},[centerId]);
 return <section className="panel readable"><h2>신용카드 자동결제 · 테스트</h2><p className="notice">실제 청구가 없는 테스트 전용입니다. 테스트로 활성화한 회원권도 앱에서는 이용 가능하므로 테스트 회원으로 진행하세요.</p><p>서버 환경변수의 TOSS_CLIENT_KEY와 TOSS_SECRET_KEY를 사용합니다. 이 화면에 비밀 키를 입력하지 않습니다.</p><p>현재 설정: {config?`${config.mode==='test'?'테스트':'기존 운영'} · ${config.enabled?'신규 결제 허용':'신규 결제 중단'}`:'미등록'}</p><p>기존 테스트 일회성 결제 설정과 기존 계약의 결제 계정은 유지됩니다. 처음 연결하는 지점은 빌링 전용으로 시작합니다.</p><button disabled={!isOwner||busy} onClick={async()=>{setBusy(true);try{await paymentAction({action:'configure_env',centerId,enabled:true});await load();setMessage('서버 테스트 키를 이 지점에 연결했습니다.');}catch(e){setMessage(friendlyError(e));}finally{setBusy(false)}}}>서버 테스트 키로 빌링 연결</button>{message&&<p role="status">{message}</p>}</section>;
}

export function BillingHistory({centerId}:{centerId:string}){
 const [rows,setRows]=useState<any[]>([]),[page,setPage]=useState(0),[busy,setBusy]=useState(false),[message,setMessage]=useState('');
 async function load(){setBusy(true);try{const {data,error}=await db.rpc('gym_admin_billing',{cid:centerId,page_number:page});if(error)throw error;setRows(data??[]);}catch(e){setMessage(friendlyError(e));}finally{setBusy(false)}}
 useEffect(()=>{setRows([]);void load()},[centerId,page]);
 const date=(v:string|null)=>v?new Date(v).toLocaleString('ko-KR',{timeZone:'Asia/Seoul'}):'없음';
 return <section><h2>결제내역 · 다음 결제일</h2><p>실패·확인 대기 주문은 회원권을 활성화하지 않습니다. 일시 오류는 5분·30분·2시간 간격으로 최대 3회 재시도하고, 카드 거절은 자동 재청구하지 않습니다.</p><button className="secondary" disabled={busy} onClick={()=>void load()}>새로고침</button>{message&&<p className="notice" role="status">{message}</p>}{rows.map(r=><article className="panel" key={r.id}><span className="badge gray">{r.mode==='test'?'테스트 · 실제 청구 없음':'기존 운영 기록'}</span><h3>{r.member_name} · {r.product_name}</h3><p>{money(Number(r.amount))} · {{PENDING:'결제 대기',PROCESSING:'승인 확인 중',PAID:'승인 완료',FAILED:'결제 실패',CANCELED:'취소됨'}[r.status as string]??r.status}{r.review_required?' · 관리자 확인 필요':''}</p><p>주문: {r.id}</p><p>접수 {date(r.created_at)} / 승인 {date(r.paid_at)}</p><p>구독 다음 결제 예정: {date(r.next_payment_at)}</p><p>처리 시도 {r.attempt_count}회 / 다음 결과 확인: {date(r.next_attempt_at)}</p>{r.last_error_code&&<p>처리 코드: {r.last_error_code}</p>}{r.mode==='test'&&r.status==='PROCESSING'&&<button className="secondary" disabled={busy} onClick={async()=>{setBusy(true);try{await paymentAction({action:'reconcile',orderId:r.id});setMessage('토스 승인 내역을 확인하고 반영했습니다.');}catch(e){setMessage(friendlyError(e));}finally{await load()}}}>승인 내역 조회 · 추가 청구 없음</button>}</article>)}{!rows.length&&!busy&&<p>표시할 결제내역이 없습니다.</p>}<div className="toolbar"><button disabled={busy||page===0} onClick={()=>setPage(p=>p-1)}>이전</button><span>{page+1}페이지 · 50건씩 표시</span><button disabled={busy||rows.length<50} onClick={()=>setPage(p=>p+1)}>다음</button></div></section>;
}
