/* Account-scoped damage / overdue rotation. ES5 for TV browsers. */
(function(root){
 "use strict";
 root.GREENLOOP_TV_ROTATION=function(api,hooks){
  var active=false,epoch=0,settings=null,current="none",timer=null,deadline=0,paused=false,detail=null,detailPage=0,detailTotal=0,configRequest=0,cardRequest=0,phoneRequest=0,configBusy=false,roster=[],month="",wasHidden=!!document.hidden;
  function get(id){return document.getElementById(id);}
  function text(id,s){get(id).textContent=String(s===null||s===undefined?"":s);}
  function esc(s){return String(s===null||s===undefined?"":s).replace(/[&<>"']/g,function(c){return{"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];});}
  function message(s){text("tvr-message",s||"");get("tvr-message").style.display=s?"block":"none";}
  function sig(s){return s?JSON.stringify([s.show_damage,s.show_overdue,s.damage_seconds,s.pending_seconds,s.overdue_days,s.revision,s.access_revision]):"";}
  function both(){return settings&&settings.show_damage&&settings.show_overdue;}
  function reading(){return !!detail||(current==="damage"&&hooks.damageReading&&hooks.damageReading());}
  function clearTimer(){timer=null;deadline=0;}
  function monthKey(){var d=new Date(new Date().getTime()+14400000);return d.getUTCFullYear()+"-"+d.getUTCMonth();}
  function status(){get("tvr-switch-controls").style.display=active&&both()?"flex":"none";get("tvr-switch-pause").disabled=false;get("tvr-switch-pause").setAttribute("aria-pressed",paused?"true":"false");text("tvr-switch-pause",paused||reading()?"Resume switching":"Pause switching");text("tvr-window-status",reading()?"Switching paused for details · Resume switching to continue":paused?"Screen switching paused":(current==="damage"?"Damage Report":"Overdue Lab & Glass")+" · "+Math.max(1,Math.ceil((deadline-new Date().getTime())/1000))+" sec");}
  function plan(){clearTimer();if(active&&both()&&!paused&&!reading()&&!document.hidden&&current!=="none"){deadline=new Date().getTime()+(current==="damage"?settings.damage_seconds:settings.pending_seconds)*1000;timer=true;}status();}
  function clearPhones(){phoneRequest++;get("tvr-phone-rows").innerHTML="";text("tvr-detail-title","");text("tvr-detail-info","");text("tvr-phone-range","");detail=null;detailPage=0;detailTotal=0;get("tvr-detail").style.display="none";get("tvr-cards-view").style.display="block";}
  function clearOverdue(){cardRequest++;roster=[];get("tvr-cards").innerHTML="";text("tvr-total","");clearPhones();message("");}
  function hideViews(){current="none";clearTimer();get("tvr-damage-view").style.display="none";get("tvr-overdue-view").style.display="none";document.body.setAttribute("data-tv-window","none");hooks.pauseDamage();}
  function error(e){if(!active)return;if(e&&(e.clearSession||/^(NO_SESSION|SESSION_EXPIRED|PERMISSION_DENIED)$/.test(e.code||""))){stop();hooks.expired(e);return;}message(e&&e.message||"Pending phones could not be refreshed. Select Refresh now to retry.");}
  function apply(s){var changed=sig(s)!==sig(settings);if(changed){settings=s;clearOverdue();if(hooks.clearDamage)hooks.clearDamage();paused=false;clearTimer();enter(s.show_damage?"damage":s.show_overdue?"overdue":"none");}return changed;}
  function fresh(s){if(sig(s)!==sig(settings)){refresh();return false;}return true;}
  function elapsed(n){var minutes=Math.floor(Number(n)/60),days=Math.floor(minutes/1440),hours=Math.floor(minutes%1440/60),mins=minutes%60;return(days?days+"d ":"")+(hours?hours+"h ":"")+(mins?mins+"m":"");}
  function oldestDays(seconds){var days=Math.floor(Number(seconds)/86400);return days+" "+(days===1?"Day":"Days");}
  function cards(){if(!active||!settings||!settings.show_overdue)return;var life=epoch,request=++cardRequest,collected=[],seen={},first=null;message("Loading overdue phones…");
   function page(offset){api.loadOverdueCards(offset,100,function(e,d){if(!active||life!==epoch||request!==cardRequest)return;if(e){get("tvr-cards").innerHTML="";roster=[];error(e);if(e.serverCode==="22023")refresh();return;}if(!fresh(d.settings))return;
    if(!first)first=d;else if(d.employee_count!==first.employee_count||d.phone_count!==first.phone_count){message("Pending phones changed while loading. Refresh to retry.");return;}
    for(var i=0;i<d.employees.length;i++){var employee=d.employees[i];if(seen[employee.employee_key]){message("The employee cards could not be verified. Refresh to retry.");return;}seen[employee.employee_key]=true;collected.push(employee);}
    if(d.has_more){page(collected.length);return;}var total=0;for(i=0;i<collected.length;i++)total+=collected[i].phone_count;if(collected.length!==d.employee_count||total!==d.phone_count){message("Complete pending-phone totals could not be verified. Refresh to retry.");return;}
    roster=collected;get("tvr-cards").className="tvr-cards"+(roster.length>18?" is-dense":"");text("tv-last-updated","Updated "+hooks.date(d.server_now)+" UAE");if(hooks.live)hooks.live();text("tvr-total",d.phone_count+" overdue phone"+(d.phone_count===1?"":"s")+" · "+d.employee_count+" employee"+(d.employee_count===1?"":"s"));var html="";
    for(i=0;i<roster.length;i++){employee=roster[i];html+='<button class="tvr-card" type="button" data-tvr-employee="'+esc(employee.employee_key)+'"><span class="tvr-card-name">'+esc(employee.employee_name)+'</span><strong class="tvr-card-count">'+employee.phone_count+'</strong><span class="tvr-card-label">phone'+(employee.phone_count===1?'':'s')+' pending</span><span class="tvr-card-oldest" title="Oldest pending phone: '+esc(elapsed(employee.oldest_seconds))+' · Sunday excluded">Oldest Pending: '+oldestDays(employee.oldest_seconds)+'</span><small>View phones →</small></button>';}
    get("tvr-cards").innerHTML=html||'<p class="tvr-empty">No selected employees have phones pending over '+settings.overdue_days+' day'+(settings.overdue_days===1?'':'s')+'.</p>';message("");if(current==="overdue"&&!deadline&&!reading())plan();
   });}page(0);
  }
  function phoneButtons(busy){get("tvr-prev").disabled=busy||detailPage===0;get("tvr-next").disabled=busy||detailPage+20>=detailTotal;get("tvr-details-refresh").disabled=busy;}
  function phones(){if(!active||!detail||!settings.show_overdue)return;var life=epoch,request=++phoneRequest,key=detail,offset=detailPage;get("tvr-phone-rows").innerHTML="";phoneButtons(true);message("Loading this employee's overdue phones…");
   api.loadOverduePhones(key,offset,20,function(e,d){if(!active||life!==epoch||request!==phoneRequest||detail!==key)return;if(e){error(e);phoneButtons(false);if(e.serverCode==="22023")refresh();return;}if(!fresh(d.settings))return;
    detailTotal=d.phone_count;if(detailPage&&detailPage>=detailTotal){detailPage=0;phones();return;}text("tvr-detail-title",d.employee_name||"No overdue phones remain");text("tvr-detail-info",d.phone_count+" phone"+(d.phone_count===1?"":"s")+" pending over "+settings.overdue_days+" day"+(settings.overdue_days===1?"":"s")+" · Sunday excluded");
    var html="";for(var i=0;i<d.rows.length;i++){var p=d.rows[i];html+='<tr><td><strong>'+esc(p.imei)+'</strong></td><td>'+esc(p.model)+'</td><td>'+esc(p.storage_gb>=1024?p.storage_gb/1024+' TB':p.storage_gb+' GB')+'</td><td>'+esc(p.color||'Not recorded')+'</td><td>'+esc(p.battery_health===null?'Not recorded':p.battery_health+'%')+'</td><td>'+esc(p.supplier_code||'Not recorded')+'</td><td>'+esc(p.department)+'</td><td>'+esc(hooks.date(p.entered_at))+'</td><td><strong>'+esc(elapsed(p.elapsed_seconds))+'</strong></td></tr>';}
    get("tvr-phone-rows").innerHTML=html||'<tr><td colspan="9">No phones remain overdue for this employee.</td></tr>';text("tv-last-updated","Updated "+hooks.date(d.server_now)+" UAE");if(hooks.live)hooks.live();text("tvr-phone-range",d.phone_count?(detailPage+1)+"–"+Math.min(detailPage+20,d.phone_count)+" of "+d.phone_count:"0 phones");phoneButtons(false);message("");
   });
  }
  function enter(next){if(!active||!settings)return;current=next;clearTimer();hooks.pauseDamage();get("tvr-damage-view").style.display=next==="damage"?"block":"none";get("tvr-overdue-view").style.display=next==="overdue"?"block":"none";document.body.setAttribute("data-tv-window",next);
   text("tv-board-message","");get("tv-board-message").style.display="none";
   text("tv-board-title",next==="damage"?"Live Damage Report":next==="overdue"?"Overdue Lab & Glass":"TV display access");text("tvr-title","Pending over "+settings.overdue_days+" day"+(settings.overdue_days===1?"":"s")+" · Sunday excluded");
   if(next==="damage"){clearPhones();hooks.damage();}else if(next==="overdue"){clearPhones();cards();}else{text("tv-board-message","No TV windows are enabled for this account. Ask an administrator to check User Access.");get("tv-board-message").style.display="block";}plan();
  }
  function refresh(){if(!active||configBusy)return;configBusy=true;var life=epoch,request=++configRequest;api.loadTvRotation(function(e,s){if(life!==epoch||request!==configRequest||!active)return;configBusy=false;if(e){hideViews();clearOverdue();text("tv-board-message",e.message||"TV settings could not be verified. Refresh to retry.");get("tv-board-message").style.display="block";error(e);return;}
   var changed=apply(s);if(!changed){if(current==="none"&&(s.show_damage||s.show_overdue)){enter(s.show_damage?"damage":"overdue");return;}if(current==="damage")hooks.refreshDamage();else if(current==="overdue"){if(detail)phones();else cards();}}
  });}
  function start(){stop();month=monthKey();wasHidden=!!document.hidden;active=true;epoch++;hideViews();text("tv-board-message","Loading TV window settings…");get("tv-board-message").style.display="block";refresh();}
  function stop(){active=false;epoch++;configRequest++;configBusy=false;settings=null;clearTimer();if(!get("tvr-damage-view"))return;clearOverdue();hideViews();get("tvr-switch-controls").style.display="none";}
  get("tvr-cards").onclick=function(event){var node=(event||root.event).target||(event||root.event).srcElement;while(node&&node!==this&&!node.getAttribute("data-tvr-employee"))node=node.parentNode;if(!node||node===this)return;var key=node.getAttribute("data-tvr-employee"),employee=null;for(var i=0;i<roster.length;i++)if(roster[i].employee_key===key)employee=roster[i];if(!employee||!active||current!=="overdue")return;clearTimer();detail=key;detailPage=0;detailTotal=employee.phone_count;text("tvr-detail-title",employee.employee_name);get("tvr-cards-view").style.display="none";get("tvr-detail").style.display="block";status();phones();get("tvr-detail-title").focus();};
  get("tvr-back").onclick=function(){clearPhones();cards();plan();get("tvr-title").setAttribute("tabindex","-1");get("tvr-title").focus();};
  get("tvr-prev").onclick=function(){if(detailPage>=20){detailPage-=20;phones();}};get("tvr-next").onclick=function(){if(detailPage+20<detailTotal){detailPage+=20;phones();}};get("tvr-details-refresh").onclick=phones;
  get("tvr-switch-pause").onclick=function(){if(reading()){clearPhones();if(current==="damage"&&hooks.resumeDamage)hooks.resumeDamage();paused=false;}else paused=!paused;plan();};
  // A deadline heartbeat survives missed timer callbacks. Data refreshes never
  // restart an unchanged interval; only a new view/settings/resume does.
  root.setInterval(function(){if(!active)return;var nextMonth=monthKey();if(nextMonth!==month){month=nextMonth;if(hooks.clearDamage)hooks.clearDamage();if(current==="damage")hooks.refreshDamage();}
   if(!both())return;if(reading()||paused||document.hidden){if(timer!==null)clearTimer();}else if(current!=="none"){if(timer===null)plan();else if(new Date().getTime()>=deadline)enter(current==="damage"?"overdue":"damage");}status();
  },250);
  document.addEventListener("visibilitychange",function(){var hidden=!!document.hidden;if(hidden===wasHidden)return;wasHidden=hidden;clearTimer();if(!hidden&&active){plan();refresh();}});root.addEventListener("pagehide",stop);
  root.addEventListener("greenloop:office-locked",function(){active=false;epoch++;configRequest++;configBusy=false;settings=null;clearTimer();});
  return{start:start,stop:stop,refresh:refresh,isDamageView:function(){return active&&current==="damage"&&settings&&settings.show_damage;}};
 };
}(window));
