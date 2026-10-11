import {createClient} from '@supabase/supabase-js';
import type {State,Center,Product} from '../lib/model';
declare const __SUPABASE_URL__:string;
declare const __SUPABASE_KEY__:string;
export const db=createClient(__SUPABASE_URL__,__SUPABASE_KEY__,{auth:{storageKey:'any-boxing-myweb1-auth',detectSessionInUrl:true,persistSession:true,autoRefreshToken:true}});
export let passwordRecoveryVerified=false;
db.auth.onAuthStateChange(event=>{if(event==='PASSWORD_RECOVERY')passwordRecoveryVerified=true;if(event==='SIGNED_OUT')passwordRecoveryVerified=false;});
const imageIds=new Map<string,string>();
const empty=():State=>({centers:[],products:[],members:[],subscriptions:[],lockers:[],payments:[],attendance:[],priceHistory:[],lockerHistory:[],paymentConfigs:[],orders:[]});
function checked<T>(r:{data:T,error:any}):NonNullable<T> {if(r.error)throw r.error;if(r.data==null)throw Error("서버 응답이 비어 있습니다.");return r.data;}
export async function loadCatalog(){
 const [centers,appearances,products,prices,access,media]=await Promise.all([
  db.from('centers').select('*').order('created_at'),db.from('center_appearance').select('*'),db.from('products').select('*').order('sort_order'),
  db.from('product_prices').select('*').lte('effective_at',new Date().toISOString()).order('effective_at',{ascending:false}).order('id',{ascending:false}),
  db.from('product_access_centers').select('*'),db.rpc('gym_catalog_media')
 ]).then(rs=>rs.map(checked)) as any[][];
 const urls=new Map<string,string>();
 await Promise.all(media.map(async m=>{const r=await db.storage.from('center-media').createSignedUrl(m.object_path,3600);if(r.error)throw r.error;urls.set(m.id,r.data.signedUrl);imageIds.set(r.data.signedUrl,m.id);}));
 const state=empty();
 state.centers=centers.map(c=>{const a=appearances.find(a=>a.center_id===c.id);return {id:c.id,businessName:c.business_name??'',representative:c.representative??'',businessAddress:c.business_address??'',businessPhone:c.business_phone??'',name:c.name,brand:c.brand,address:c.address,phone:c.phone,active:c.active,bgColor:a?.background_color??'#102e2b',bgImage:urls.get(a?.background_image_id)??'',headline:a?.headline??'오늘도, 나를 넘어서.',overlay:a?.image_overlay??40} as Center});
 state.products=products.map(p=>({id:p.id,details:p.details??'',terms:p.terms??'',cancellationNotice:p.cancellation_notice??'',intervalUnit:p.interval_unit??'month',intervalCount:p.interval_count??1,revision:p.revision??1,centerId:p.center_id,name:p.name,description:p.description,category:p.category,recurring:p.recurring,weeklyLimit:p.weekly_limit,capacity:p.capacity,stock:p.stock,active:p.active,selling:p.selling,sort:p.sort_order,image:urls.get(p.image_id)??'',price:Number(prices.find(x=>x.product_id===p.id)?.amount??0),accessCenters:access.filter(a=>a.product_id===p.id).map(a=>a.center_id)} as Product));
 return state;
}
export async function loadRoles(){const {data:{session}}=await db.auth.getSession();if(!session)return [];return checked(await db.from('center_admins').select('center_id,role').eq('user_id',session.user.id));}
export async function saveCatalog(action:string,input:any){
 const name=action==='center.save'?'gym_save_center_v2':action==='product.save'?'gym_save_product_v2':null;
 if(!name)throw Error('아직 연결하지 않은 기능입니다.');
 const image=action==='center.save'?input.bgImage:input.image;
 if(image&&!imageIds.has(image))throw Error('사진 정보를 다시 불러온 뒤 저장해 주세요.');
 return checked(await db.rpc(name,{payload:{...input,imageId:image?imageIds.get(image):null}}));
}
export async function uploadImage(centerId:string,file:File){
 if(!['image/jpeg','image/png','image/webp'].includes(file.type)||file.size>5242880)throw Error('5MB 이하의 JPG, PNG, WebP 사진을 선택해 주세요.');
 const id=crypto.randomUUID(),ext=file.type==='image/jpeg'?'jpg':file.type==='image/png'?'png':'webp',path=centerId+'/'+id+'.'+ext;
 checked(await db.storage.from('center-media').upload(path,file,{contentType:file.type,upsert:false}));
 checked(await db.rpc('gym_register_media',{payload:{id,centerId,path,type:file.type,size:file.size}}));
 const signed=checked(await db.storage.from('center-media').createSignedUrl(path,3600));
 imageIds.set(signed.signedUrl,id);return signed.signedUrl;
}
export function friendlyError(e:unknown){const message=e instanceof Error?e.message:(e as any)?.message??'요청에 실패했습니다.';if(/schema cache|does not exist/.test(message))return '추가 DB 설정이 필요합니다. 관리자에게 최신 SQL(05번 및 07번) 적용 여부를 확인해 주세요.';if(/Invalid login credentials/.test(message))return '이메일 또는 비밀번호를 확인해 주세요.';if(/Email not confirmed/.test(message))return '가입 이메일의 인증 링크를 먼저 눌러 주세요.';return message;}

export async function updateProfile(name:string,phone:string){const {error}=await db.rpc('gym_update_profile',{payload:{name,phone}});if(error)throw error;}
export async function memberData(){const {data:{session}}=await db.auth.getSession();if(!session)return {profile:null,memberships:[]};const [p,m]=await Promise.all([db.from('profiles').select('name,phone').eq('id',session.user.id).single(),db.from('gym_memberships').select('*').eq('member_id',session.user.id).order('created_at',{ascending:false})]);return {profile:checked(p),memberships:checked(m)};}
export async function listLockers(centerId:string){return checked(await db.rpc('gym_list_lockers',{cid:centerId})) as any[];}
export async function saveLocker(payload:any){return checked(await db.rpc('gym_save_locker',{payload}));}
export async function getTossConfig(centerId:string){const r=await db.from('payment_configs').select('*').eq('center_id',centerId).eq('is_current',true).maybeSingle();if(r.error)throw r.error;return r.data;}
export async function paymentAction(body:any){const {data,error}=await db.functions.invoke('gym-payments',{body});if(error){let message='결제 서버에 연결하지 못했습니다. 센터에 문의해 주세요.';try{const response=await error.context?.json();if(response?.error)message=response.error;}catch{}throw Error(message);}if(data?.error)throw Error(data.error);return data;}
export async function cancelMembership(mid:string){const {error}=await db.rpc('gym_cancel_membership',{mid});if(error)throw error;}
let sdkPromise:Promise<any>|null=null;
async function tossSdk(){if((window as any).TossPayments)return (window as any).TossPayments;if(!sdkPromise)sdkPromise=new Promise((resolve,reject)=>{const script=document.createElement('script');script.src='https://js.tosspayments.com/v2/standard';script.onload=()=>resolve((window as any).TossPayments);script.onerror=()=>{sdkPromise=null;script.remove();reject(Error('결제창을 불러오지 못했습니다.'));};document.head.appendChild(script);});return sdkPromise;}
export async function beginCheckout(product:Product,lockerId:string,agreed:boolean){
 const sdk=await tossSdk();
 const order=checked(await db.rpc('gym_prepare_checkout',{payload:{productId:product.id,revision:product.revision,lockerId:lockerId||null,agreed}}));
 const payment=sdk(order.clientKey).payment({customerKey:order.customerKey});
 const base=location.origin+import.meta.env.BASE_URL;
 const successUrl=base+'?flow='+(order.recurring?'billing':'payment')+'&orderId='+order.orderId;
 const failUrl=base+'?flow=failed';
 if(order.recurring)await payment.requestBillingAuth({method:'CARD',successUrl,failUrl});
 else await payment.requestPayment({method:'CARD',amount:{currency:'KRW',value:order.amount},orderId:order.orderId,orderName:order.orderName,successUrl,failUrl});
}
