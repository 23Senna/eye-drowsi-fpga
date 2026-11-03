"""Portable self-checking simulation runner; generated data stays under build/."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', action='store_true', help='Test the committed HEAD before local edits')
    parser.add_argument('--only', nargs='*', help='Test names; default: full regression')
    args=parser.parse_args()
    # Windows compiler subprocesses (ivl.exe) need DLLs next to iverilog.exe.
    compiler=shutil.which('iverilog')
    if compiler:
        os.environ['PATH']=str(Path(compiler).resolve().parent)+os.pathsep+os.environ.get('PATH','')
    root=Path(__file__).resolve().parents[2]
    run=root/'build'/('verify_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    src=run/'source';src.mkdir(parents=True)
    git=['git','-c','safe.directory='+root.as_posix(),'-C',str(root)]
    revision=subprocess.check_output(git+['rev-parse','HEAD'],text=True).strip()
    if args.baseline:
        names=subprocess.check_output(git+['ls-files'],text=True).splitlines()
        for name in names:
            if not name.startswith(('rtl/','sim/','integration/','ml/export/')):continue
            if Path(name).suffix not in ('.v','.vh','.py','.mem','.txt','.sh'):continue
            dst=src/name;dst.parent.mkdir(parents=True,exist_ok=True)
            dst.write_bytes(subprocess.check_output(git+['show','HEAD:'+name]))
    else:
        for folder in ['rtl','sim','integration','ml/export']:
            for p in (root/folder).rglob('*'):
                if p.is_file() and p.suffix in ('.v','.vh','.py','.mem','.txt','.sh') and not any(x in ('build','__pycache__','vivado','reports') for x in p.relative_to(root).parts):
                    dst=src/p.relative_to(root);dst.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dst)
    report={'base_revision':revision,'baseline':args.baseline,'python':sys.version,'tests':[],
            'sources':{p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in src.rglob('*') if p.is_file()}}
    print('Evidence:',run,flush=True)

    def command(name,cmd,cwd=src,expect_failure=False):
        (run/(name+'.command.json')).write_text(json.dumps([str(x) for x in cmd]))
        try:
            with (run/(name+'.log')).open('w',encoding='utf-8') as output:
                p=subprocess.run([str(x) for x in cmd],cwd=cwd,stdout=output,stderr=subprocess.STDOUT,timeout=600)
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(name+' timed out; partial output retained in log') from exc
        text=(run/(name+'.log')).read_text(encoding='utf-8',errors='replace')
        if expect_failure:
            if p.returncode == 0: raise RuntimeError(name+' unexpectedly succeeded')
        elif p.returncode:raise RuntimeError(f'{name}: exit {p.returncode}\n{text[-2000:]}')
        return text

    command('generate_integration',[sys.executable,src/'integration/scripts/gen_sim_data.py'])
    if not args.baseline:
        command('generate_upload',[sys.executable,src/'integration/scripts/gen_upload_vectors.py'])
    unit=run/'unit';mem=unit/'mem';mem.mkdir(parents=True)
    for p in (src/'ml/export').iterdir():
        if p.suffix=='.mem' or p.name=='params.txt':shutil.copyfile(p,mem/p.name)
    command('generate_units',[sys.executable,src/'sim/unit/gen_vectors.py'],unit)
    rtl=src/'rtl';ir=src/'integration/rtl';sim=src/'integration/sim'
    cnn=[rtl/(m+'.v') for m in ['cnn_top','rom_weights','conv1_layer','conv2_layer','fc_layer','mac_pipe','relu_requant','maxpool2x2']]
    core=[ir/(m+'.v') for m in ['drowsiness_top','input_control','drowsy_fsm','alert_control']]
    serial=[ir/(m+'.v') for m in ['uart_rx','uart_tx','uart_command','uart_ascii_tx','uart_monitor','uart_image_rx']] if not args.baseline else []
    stub=[ir/(m+'.v') for m in ['cnn_core_stub','image_rom','weight_bias_rom']]
    tests={
        'tb_cnn':(src/'sim/tb_cnn.v',cnn,src/'ml/export',[]),
        **{n:(src/'sim/unit'/(n+'.v'),[rtl/'conv_pe.v',rtl/'relu_requant.v'],mem,[]) for n in ['tb_relu_requant','tb_conv_pe','tb_conv_relu_golden']},
        'tb_input_control':(sim/'tb_input_control.v',[ir/'input_control.v'],sim,[]),
        'tb_alert_control':(sim/'tb_alert_control.v',[ir/'alert_control.v'],sim,[]),
        'tb_drowsy_fsm':(sim/'tb_drowsy_fsm.v',[ir/'drowsy_fsm.v'],sim,[]),
        'tb_roms':(sim/'tb_roms.v',[ir/'image_rom.v',ir/'weight_bias_rom.v'],sim,[]),
        'tb_cnn_control':(sim/'tb_cnn_control.v',[ir/'cnn_control.v'],sim,[]),
        'tb_top':(sim/'tb_top.v',core+serial+stub,sim,['-DUSE_STUB']),
        'tb_top_real':(sim/'tb_top_real.v',core+serial+cnn,sim,[])}
    tests.update({
        'tb_conv1_layer':(src/'sim/tb_conv1_layer.v',[rtl/(m+'.v') for m in ['conv1_layer','mac_pipe','relu_requant','maxpool2x2']],src/'ml/export',[]),
        'tb_conv2_layer':(src/'sim/tb_conv2_layer.v',[rtl/(m+'.v') for m in ['conv2_layer','mac_pipe','relu_requant','maxpool2x2']],src/'ml/export',[]),
        'tb_fc_layer':(src/'sim/tb_fc_layer.v',[rtl/'fc_layer.v',rtl/'mac_pipe.v'],src/'ml/export',[])})
    if not args.baseline:
        tests.update({
            'tb_uart_phy':(sim/'tb_uart_phy.v',serial[:2],sim,[]),
            'tb_uart_command':(sim/'tb_uart_command.v',[ir/'uart_command.v'],sim,[]),
            'tb_uart_format':(sim/'tb_uart_format.v',serial[:2]+[ir/'uart_ascii_tx.v'],sim,[]),
            'tb_uart_latency_100':(sim/'tb_uart_latency.v',serial,sim,[]),
            'tb_uart_latency_50':(sim/'tb_uart_latency.v',serial,sim,['-P','tb_uart_latency.MHZ=50']),
            'tb_uart_system_stub':(sim/'tb_uart_system.v',core+serial+stub,sim,['-DUSE_STUB']),
            'tb_uart_system_real':(sim/'tb_uart_system.v',core+serial+cnn,sim,[])})
        tests['tb_uart_upload']=(sim/'tb_uart_upload.v',core+serial+cnn,sim,[])
    selected=args.only or list(tests)
    report['sources']={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in src.rglob('*') if p.is_file()}
    failed=False
    for name in selected:
        tb,files,cwd,opts=tests[name]
        top='tb_uart_system' if name.startswith('tb_uart_system_') else 'tb_uart_latency' if name.startswith('tb_uart_latency_') else name
        try:
            command(name+'_compile',['iverilog','-g2012','-Wall','-I',ir,'-I',sim,'-s',top,*opts,'-o',run/(name+'.vvp'),tb,*files])
            text=command(name,['vvp','-n',run/(name+'.vvp')],cwd)
            if name=='tb_cnn':
                got={int(m[1]):(int(m[2]),int(m[3])) for m in re.finditer(r'Image\s+(\d+).*?Logit0:\s*(-?\d+)\s*\|\s*Logit1:\s*(-?\d+)',text)}
                expected=[list(map(int,l.split())) for l in (src/'ml/export/expected.txt').read_text().splitlines()[1:] if l.strip()]
                assert len(got)==16 and all(got.get(i)==(l0,l1) for i,lab,pred,l0,l1 in expected)
                summary='16/16 golden logit pairs; '+str(sum((got[i][1]>got[i][0])==bool(lab) for i,lab,*_ in expected))+'/16 correct labels'
            else:
                assert 'FAIL' not in text and 'ERROR:' not in text, 'Simulator emitted FAIL/ERROR; see log'
                assert 'PASS '+top in text or re.search(r'TEST PASSED\s*:\s*'+re.escape(top),text), 'No checked PASS summary; see log'
                summary='; '.join(l for l in text.splitlines() if 'PASS' in l or 'errors' in l or 'latency' in l)
            report['tests'].append({'name':name,'status':'PASS','summary':summary});print('PASS',name,summary,flush=True)
            if name=='tb_relu_requant' and not args.baseline:
                empty=run/'missing_vectors';empty.mkdir()
                negative=command('tb_relu_missing_vectors',['vvp','-n',run/(name+'.vvp')],empty,expect_failure=True)
                assert 'missing input vectors' in negative
                report['tests'].append({'name':'tb_relu_missing_vectors','status':'PASS','summary':'Missing vectors terminate simulation with nonzero exit'})
                print('PASS tb_relu_missing_vectors (missing data fails closed)',flush=True)
        except Exception as exc:
            failed=True;report['tests'].append({'name':name,'status':'FAIL','summary':str(exc)});print('FAIL',name,str(exc),flush=True)
        (run/'summary.json').write_text(json.dumps(report,indent=2))
    print('Summary:',run/'summary.json',flush=True)
    return 1 if failed else 0


if __name__=='__main__':
    sys.exit(main())
