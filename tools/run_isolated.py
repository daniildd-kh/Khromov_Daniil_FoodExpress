#!/usr/bin/env python3
"""Проверка FoodExpress и восстановление дампа в отдельном PostgreSQL 17"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true', help='actually initialize, start and test a new private cluster')
    parser.add_argument('--work-dir', type=Path, default=Path('work/netology-foodexpress/runtime-run'))
    args = parser.parse_args()
    if not args.run:
        print('НЕ ЗАПУЩЕНО: add --run only in an environment permitting PostgreSQL shared memory')
        print('New data directory:', (args.work_dir / 'pgdata').resolve())
        print('TCP disabled; temporary private Unix socket; no existing database connections')
        return 0

    work = args.work_dir.resolve()
    if work.exists() and any(work.iterdir()):
        raise SystemExit('Refusing to reuse a nonempty work directory: ' + str(work))
    binaries = {}
    for name in ('initdb','postgres','pg_ctl','createdb','psql','pg_dump','pg_restore'):
        binaries[name] = shutil.which(name)
        if not binaries[name]:
            raise SystemExit('Required installed executable not found: ' + name)
    version = subprocess.check_output([binaries['postgres'],'--version'],text=True).strip()
    if not re.search(r'PostgreSQL\) 17\.', version):
        raise SystemExit('This runner expects PostgreSQL 17, found ' + version)
    work.mkdir(parents=True, exist_ok=True)
    logs = work / 'logs'
    logs.mkdir()
    socket = Path(tempfile.mkdtemp(prefix='netology-foodexpress-'))
    pgdata = work / 'pgdata'
    owner, port = 'foodexpress_owner', '55439'
    database, restore_database = 'foodexpress_draft', 'foodexpress_restore'
    env = {key:value for key,value in os.environ.items() if not key.startswith('PG')}
    # Do not read the user's ~/.pgpass or environment connection settings
    passfile = work / 'course.pgpass'
    passfile.write_text('*:*:*:inspector:NetoSQL2025\n',encoding='utf-8')
    passfile.chmod(0o600)
    env['PGPASSFILE'] = str(passfile)
    result = {'status':'NOT_RUN','postgres_version':version,'data_directory':str(pgdata),
              'socket_directory':str(socket),'tcp_enabled':False,'steps':[]}
    started = False

    def execute(label, argv, user=None, db=None, sql_file=None, sql=None):
        if user:
            argv = [binaries['psql'],'-X','-v','ON_ERROR_STOP=1','-h',str(socket),'-p',port,'-U',user,'-d',db]
            argv += ['-f',str(sql_file)] if sql_file else ['-c',sql]
        process = subprocess.run(argv,text=True,capture_output=True,env=env)
        logfile = logs / (label + '.log')
        logfile.write_text(process.stdout + process.stderr,encoding='utf-8')
        result['steps'].append({'step':label,'returncode':process.returncode,'log':str(logfile)})
        if process.returncode:
            raise RuntimeError(label + ' failed, see ' + str(logfile))
        return process.stdout

    def connection(user,db):
        return ['-h',str(socket),'-p',port,'-U',user,'-d',db]

    try:
        execute('01_initdb',[binaries['initdb'],'-D',str(pgdata),'-U',owner,
                            '--auth-local=trust','--auth-host=reject','--encoding=UTF8','--locale=C','--no-instructions'])
        with (pgdata / 'postgresql.conf').open('a') as file:
            file.write("\nlisten_addresses = ''\nport = 55439\nunix_socket_directories = '" + str(socket).replace("'","''") + "'\ntimezone = 'Europe/Moscow'\n")
        hba = pgdata / 'pg_hba.conf'
        hba.write_text('local all inspector scram-sha-256\n' + hba.read_text(),encoding='utf-8')
        execute('02_start',[binaries['pg_ctl'],'-D',str(pgdata),'-l',str(logs/'server.log'),'-w','start'])
        started = True
        execute('03_create_db',[binaries['createdb'],'-h',str(socket),'-p',port,'-U',owner,database])
        execute('04_bootstrap',[],owner,database,PROJECT/'tools/bootstrap_local.sql')
        for index, source in enumerate(sorted((PROJECT/'db/schema').glob('*.sql')),5):
            execute(f'{index:02d}_schema_{source.stem}',[],owner,database,source)
        execute('20_integration_tests',[],'inspector',database,PROJECT/'db/tests.sql')
        # Tests leave data empty; preserve only this project namespace
        backup = work / 'foodexpress_khromov.backup'
        execute('21_backup',[binaries['pg_dump'],*connection(owner,database),'-Fc','--schema-only',
                             '--schema=khromov_food','--no-owner','--no-acl','-f',str(backup)])
        execute('22_create_restore_db',[binaries['createdb'],'-h',str(socket),'-p',port,'-U',owner,restore_database])
        execute('23_restore_bootstrap',[],owner,restore_database,PROJECT/'tools/bootstrap_local.sql')
        execute('24_restore',[binaries['pg_restore'],*connection(owner,restore_database),'--no-owner','--no-acl',
                              '--exit-on-error',str(backup)])
        execute('25_restore_grants',[],owner,restore_database,PROJECT/'db/schema/grants.sql')
        execute('26_restore_tests',[],'inspector',restore_database,PROJECT/'db/tests.sql')
        execute('27_restore_inspector',[],'inspector',restore_database,
                sql="SELECT current_user; SET search_path=khromov_food,exts,pg_catalog; CALL insert_test_data(10); "
                    "DO $verify$ BEGIN IF (SELECT count(*) FROM get_statistic())<>10 THEN "
                    "RAISE EXCEPTION 'restore statistic count'; END IF; END; $verify$; "
                    "SELECT * FROM get_statistic(); SELECT * FROM how_much_money;")
        result.update(status='PASSED',backup=str(backup),restore_verified=True)
    except Exception as error:
        result.update(status='FAILED_OR_BLOCKED',error=str(error),restore_verified=False)
    finally:
        if started:
            stopped = subprocess.run([binaries['pg_ctl'],'-D',str(pgdata),'-m','fast','-w','stop'],
                                     text=True,capture_output=True,env=env)
            (logs/'99_stop.log').write_text(stopped.stdout+stopped.stderr,encoding='utf-8')
            result['server_stopped'] = stopped.returncode == 0
            if stopped.returncode:
                result['status']='FAILED_OR_BLOCKED'
        (work/'runtime_result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False,indent=2))
    return 0 if result['status']=='PASSED' else 1


if __name__=='__main__':
    sys.exit(main())
