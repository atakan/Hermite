#include <cstdio>
#include "vector3.h"
#define CUDA_TITAN
#include "hermite4.h"
// #include "hermite4-titan.h"

__global__ void predict_kernel(
		const int                 nbody,
		const Gravity::GParticle *ptcl,
		Gravity::GPredictor      *pred,
		const double              tsys)
{
	const int tid = threadIdx.x + blockDim.x * blockIdx.x;
	if(tid < nbody){
		Gravity::GParticle   p  = ptcl[tid];
		Gravity::GPredictor &pr = pred[tid];

		const double dt = tsys - p.tlast;
		const double dt2 = (1./2.) * dt;
		const double dt3 = (1./3.) * dt;

		double3 pos, vel;
		pos.x = 
			p.pos.x + dt *(
			p.vel.x + dt2*(
			p.acc.x + dt3*(
			p.jrk.x )));
		pos.y = 
			p.pos.y + dt *(
			p.vel.y + dt2*(
			p.acc.y + dt3*(
			p.jrk.y )));
		pos.z = 
			p.pos.z + dt *(
			p.vel.z + dt2*(
			p.acc.z + dt3*(
			p.jrk.z )));
		vel.x = 
			p.vel.x + dt *(
			p.acc.x + dt2*(
			p.jrk.x ));
		vel.y = 
			p.vel.y + dt *(
			p.acc.y + dt2*(
			p.jrk.y ));
		vel.z = 
			p.vel.z + dt *(
			p.acc.z + dt2*(
			p.jrk.z ));

		pr.pos  = pos;
		pr.mass = p.mass;
		pr.vel  = vel;
	}
}

void Gravity::predict_all(const double tsys){
	ptcl.htod(njpsend);
	
	const int nblock = (nbody/NTHREAD) + 
	                  ((nbody%NTHREAD) ? 1 : 0);
	predict_kernel <<<nblock, NTHREAD>>>
		(nbody, ptcl, pred, tsys);

	pred.dtoh();
	// puts("pred all done");
}

enum{
	NJBLOCK = Gravity::NJBLOCK,
};

__global__ void force_kernel(
		const int                  is,
		const int                  ie,
		const int                  nj,
		const Gravity::GPredictor *pred,
		const double               eps2,
		Gravity::GForce          (*fo)[NJBLOCK])
{
	const int xid = threadIdx.x + blockDim.x * blockIdx.x;
	const int yid = blockIdx.y;

	const int js = ((0 + yid) * nj) / NJBLOCK;
	const int je = ((1 + yid) * nj) / NJBLOCK;

	const int i = is + xid;
	if(i < ie){
		const Gravity::GPredictor ipred = pred[i];
		double3 acc = make_double3(0.0, 0.0, 0.0);
		double3 jrk = make_double3(0.0, 0.0, 0.0);

#pragma unroll 4
		for(int j=js; j<je; j++){
			const Gravity::GPredictor &jpred = pred[j];
			
			const double dx  = jpred.pos.x - ipred.pos.x;
			const double dy  = jpred.pos.y - ipred.pos.y;
			const double dz  = jpred.pos.z - ipred.pos.z;
			const double dvx = jpred.vel.x - ipred.vel.x;
			const double dvy = jpred.vel.y - ipred.vel.y;
			const double dvz = jpred.vel.z - ipred.vel.z;
			const double mj  = jpred.mass;

			const double dr2  = eps2 + dx*dx + dy*dy + dz*dz;
			const double drdv = dx*dvx + dy*dvy + dz*dvz;

			const double rinv1 = rsqrt(dr2);
			const double rinv2 = rinv1 * rinv1;
			const double mrinv3 = mj * rinv1 * rinv2;

			double alpha = drdv * rinv2;
			alpha *= -3.0;

			acc.x += mrinv3 * dx;
			acc.y += mrinv3 * dy;
			acc.z += mrinv3 * dz;
			jrk.x += mrinv3 * (dvx + alpha * dx);
			jrk.y += mrinv3 * (dvy + alpha * dy);
			jrk.z += mrinv3 * (dvz + alpha * dz);
		}

		fo[xid][yid].acc = acc;
		fo[xid][yid].jrk = jrk;
	}
}

__device__ double shfl_xor(const double x, const int bit){
	const int hi = __shfl_xor(__double2hiint(x), bit);
	const int lo = __shfl_xor(__double2loint(x), bit);
	return __hiloint2double(hi, lo);
}

__device__ double warp_reduce_double(double x){
	x += shfl_xor(x, 16);
	x += shfl_xor(x,  8);
	x += shfl_xor(x,  4);
	x += shfl_xor(x,  2);
	x += shfl_xor(x,  1);
	return x;
}

__global__ void reduce_kernel(
		const Gravity::GForce (*fpart)[NJBLOCK],
		Gravity::GForce        *ftot)
{
	const int bid = blockIdx.x;  // for particle
	const int xid = threadIdx.x; // for 30 partial force
	const int yid = threadIdx.y; // for 6 elements of Force

	const Gravity::GForce &fsrc = fpart[bid][xid];
	const double          *dsrc = (const double *)(&fsrc);
	
	const double x = xid<NJBLOCK ? dsrc[yid] : 0.0;
	const double y = warp_reduce_double(x);

	Gravity::GForce &fdst = ftot[bid];
	double          *ddst = (double *)(&fdst);
	if(32 == Gravity::NJREDUCE){
		if(0==xid) ddst[yid] = y;
	}
	if(64 == Gravity::NJREDUCE){
		// neees inter-warp reduction
		__shared__ double fsh[6][2];
		fsh[yid][xid/32] = y;
		__syncthreads();
		if(0==xid) ddst[yid] = fsh[yid][0] + fsh[yid][1];
	}
}

void Gravity::calc_force_in_range(
	   	const int    is,
		const int    ie,
		const double eps2,
		Force        force[] )
{
	const int ni = ie - is;
	{
		const int niblock = (ni/NTHREAD) + 
						   ((ni%NTHREAD) ? 1 : 0);
		dim3 grid(niblock, NJBLOCK, 1);
		force_kernel <<<grid, NTHREAD>>>
			(is, ie, nbody, pred, eps2, fpart);
	}

	{
		// const int nwarp = 32;
		const int nword = sizeof(GForce) / sizeof(double);
		assert(6 == nword);
		reduce_kernel <<<ni, dim3(NJREDUCE, nword, 1)>>>
			(fpart, ftot);
	}

	ftot.dtoh(ni);
	for(int i=0; i<ni; i++){
		force[is+i].acc.x = ftot[i].acc.x;
		force[is+i].acc.y = ftot[i].acc.y;
		force[is+i].acc.z = ftot[i].acc.z;
		force[is+i].jrk.x = ftot[i].jrk.x;
		force[is+i].jrk.y = ftot[i].jrk.y;
		force[is+i].jrk.z = ftot[i].jrk.z;
	}
}

#include "pot-titan.hu"